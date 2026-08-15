#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>

#include "uv.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

typedef int (*luaopen_luv_fn)(lua_State *L);
typedef void (*luv_set_loop_fn)(lua_State *L, uv_loop_t *loop);

/*
 * 保存 luv.so 相关句柄和函数指针
 */
typedef struct luv_lib {
    void *handle;
    luaopen_luv_fn luaopen_luv;
    luv_set_loop_fn luv_set_loop;
    char path[PATH_MAX];
} luv_lib;

/*
 * 从 package.cpath 里找 luv.so
 *
 * 例如 package.cpath:
 *   ./?.so;/usr/local/lib/lua/5.1/?.so
 *
 * 会尝试:
 *   ./luv.so
 *   /usr/local/lib/lua/5.1/luv.so
 */
static inline int find_luv_so_from_cpath(lua_State *L, char *out, size_t out_size) {
    const char *cpath;
    const char *p;

    lua_getglobal(L, "package");          /* package */
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }

    lua_getfield(L, -1, "cpath");         /* package, package.cpath */
    if (!lua_isstring(L, -1)) {
        lua_pop(L, 2);
        return 0;
    }

    cpath = lua_tostring(L, -1);
    p = cpath;

    while (*p) {
        const char *semi = strchr(p, ';');
        size_t len = semi ? (size_t)(semi - p) : strlen(p);

        char tmpl[PATH_MAX];
        char candidate[PATH_MAX];
        char *qmark;

        if (len > 0 && len < sizeof(tmpl)) {
            memcpy(tmpl, p, len);
            tmpl[len] = '\0';

            /*
             * Lua 的 cpath 模板里 ? 替换为模块名。
             * 这里模块名固定是 luv。
             */
            qmark = strchr(tmpl, '?');

            if (qmark) {
                size_t prefix_len = (size_t)(qmark - tmpl);
                const char *suffix = qmark + 1;

                snprintf(candidate,
                         sizeof(candidate),
                         "%.*sluv%s",
                         (int)prefix_len,
                         tmpl,
                         suffix);
            } else {
                /*
                 * 没有 ? 的模板意义不大，但保留兼容。
                 */
                snprintf(candidate, sizeof(candidate), "%s", tmpl);
            }

            if (access(candidate, R_OK) == 0) {
                snprintf(out, out_size, "%s", candidate);
                lua_pop(L, 2);            /* pop cpath, package */
                return 1;
            }
        }

        if (!semi)
            break;

        p = semi + 1;
    }

    lua_pop(L, 2);                        /* pop cpath, package */
    return 0;
}


/*
 * 加载 luv.so，并获取 luaopen_luv / luv_set_loop
 *
 * 成功返回 0
 * 失败返回 -1，并把错误信息写入 errbuf
 */
static inline int load_luv_symbols(lua_State *L, luv_lib *out,
                     char *errbuf, size_t errbuf_size) {
    char path[PATH_MAX];
    void *handle;
    void *sym;

    memset(out, 0, sizeof(*out));

    if (!find_luv_so_from_cpath(L, path, sizeof(path))) {
        snprintf(errbuf, errbuf_size,
                 "luv.so not found in package.cpath");
        return -1;
    }

    /*
     * RTLD_GLOBAL 很重要。
     * luv.so 可能依赖 libuv 或其他模块符号。
     */
    handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        snprintf(errbuf, errbuf_size,
                 "dlopen '%.1024s' failed: %.2048s",
                 path,
                 dlerror());
        return -1;
    }

    dlerror();  /* clear old error */

    sym = dlsym(handle, "luaopen_luv");
    if (!sym) {
        snprintf(errbuf, errbuf_size,
                 "dlsym luaopen_luv failed: %s",
                 dlerror());
        dlclose(handle);
        return -1;
    }

    _Static_assert(sizeof(out->luaopen_luv) == sizeof(sym),
        "luaopen_luv pointer representation mismatch");
    memcpy(&out->luaopen_luv, &sym, sizeof(sym));

    dlerror();  /* clear old error */

    sym = dlsym(handle, "luv_set_loop");
    if (!sym) {
        snprintf(errbuf, errbuf_size,
                 "dlsym luv_set_loop failed: %s",
                 dlerror());
        dlclose(handle);
        return -1;
    }

    _Static_assert(sizeof(out->luv_set_loop) == sizeof(sym),
        "luv_set_loop pointer representation mismatch");
    memcpy(&out->luv_set_loop, &sym, sizeof(sym));

    out->handle = handle;
    snprintf(out->path, sizeof(out->path), "%s", path);

    return 0;
}


/*
 * 如果你确定不再使用 luv.so 里的任何 C 函数，
 * 才可以调用这个。
 *
 * 通常 Lua C 模块不建议 dlclose，
 * 因为 Lua 里可能还持有 C closure 指针。
 */
static inline void unload_luv_symbols(luv_lib *lib) {
    if (lib && lib->handle) {
        dlclose(lib->handle);
        lib->handle = NULL;
        lib->luaopen_luv = NULL;
        lib->luv_set_loop = NULL;
        lib->path[0] = '\0';
    }
}

/*
 * luaopen_luv 只返回模块表，并不会像 require 那样更新
 * package.loaded。将栈顶的模块表写入 package.loaded["luv"] 后，
 * service_load_luv 会恢复调用前的 Lua 栈。
 */
static inline int cache_luv_module(lua_State *L) {
    int module_index = lua_gettop(L);

    lua_getglobal(L, "package");
    if (!lua_istable(L, -1)) {
        lua_settop(L, module_index);
        return -1;
    }

    lua_getfield(L, -1, "loaded");
    if (!lua_istable(L, -1)) {
        lua_settop(L, module_index);
        return -1;
    }

    lua_pushvalue(L, module_index);
    lua_setfield(L, -2, "luv");
    lua_settop(L, module_index);
    return 0;
}


// 准备好luv库和环境

static inline int service_load_luv(lua_State *L, uv_loop_t * loop) {
    luv_lib luv;
    char errbuf[4096];
    int nret;
    int stack_top = lua_gettop(L);
    memset(&luv,0,sizeof(luv_lib));
    memset(errbuf, 0, 4096*sizeof(char));

    if(load_luv_symbols(L, &luv, errbuf, 4096) != 0) {
        log_debug("load luv error: %s", errbuf);
        return -1;
    }

    if (loop) {
        luv.luv_set_loop(L, loop);
    }

    nret = luv.luaopen_luv(L);
    if (nret != 1) {
        log_debug("luaopen_luv returned %d values, expected 1", nret);
        lua_settop(L, stack_top);
        return -1;
    }
    if (!lua_istable(L, -1)) {
        log_debug("luaopen_luv did not return a table");
        lua_settop(L, stack_top);
        return -1;
    }

    if (cache_luv_module(L) != 0) {
        log_debug("could not register luv in package.loaded");
        lua_settop(L, stack_top);
        return -1;
    }

    lua_settop(L, stack_top);
    return 0;
}
