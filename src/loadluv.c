#include "loadluv.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <lauxlib.h>

#include "log.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

typedef int (*luaopen_luv_fn)(lua_State *L);
typedef void (*luv_set_loop_fn)(lua_State *L, uv_loop_t *loop);

typedef struct luv_loader {
    void *handle;
    luaopen_luv_fn luaopen_luv;
    luv_set_loop_fn luv_set_loop;
    char path[PATH_MAX];
    char error[1024];
    int status;
    bool prepared;
#ifdef LUV_LOADER_TESTING
    unsigned initialization_count;
#endif
} luv_loader_t;

static pthread_once_t loader_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t loader_lock = PTHREAD_MUTEX_INITIALIZER;
static luv_loader_t loader;

static int
find_luv_so(lua_State *L, char *out, size_t out_size) {
    int top = lua_gettop(L);
    const char *cursor;

    lua_getglobal(L, "package");
    if (!lua_istable(L, -1))
        goto not_found;
    lua_getfield(L, -1, "cpath");
    if (!lua_isstring(L, -1))
        goto not_found;
    cursor = lua_tostring(L, -1);

    while (*cursor != '\0') {
        const char *separator = strchr(cursor, ';');
        size_t template_length = separator ? (size_t)(separator - cursor) :
            strlen(cursor);
        const char *question = memchr(cursor, '?', template_length);
        size_t prefix_length = question ? (size_t)(question - cursor) : 0;
        size_t suffix_length = question ?
            template_length - prefix_length - 1 : 0;

        if (question != NULL && prefix_length + 3 + suffix_length < out_size) {
            memcpy(out, cursor, prefix_length);
            memcpy(out + prefix_length, "luv", 3);
            memcpy(out + prefix_length + 3, question + 1, suffix_length);
            out[prefix_length + 3 + suffix_length] = '\0';
            if (access(out, R_OK) == 0) {
                lua_settop(L, top);
                return 0;
            }
        }
        if (separator == NULL)
            break;
        cursor = separator + 1;
    }

not_found:
    lua_settop(L, top);
    return ENOENT;
}

static void
initialize_loader(void) {
    void *symbol;
    const char *detail;

#ifdef LUV_LOADER_TESTING
    loader.initialization_count++;
#endif
    if (loader.status != 0)
        return;

    loader.handle = dlopen(loader.path, RTLD_NOW | RTLD_GLOBAL);
    if (loader.handle == NULL) {
        detail = dlerror();
        snprintf(loader.error, sizeof(loader.error), "dlopen '%.480s': %.480s",
            loader.path, detail == NULL ? "unknown error" : detail);
        loader.status = ENOENT;
        return;
    }

    dlerror();
    symbol = dlsym(loader.handle, "luaopen_luv");
    detail = dlerror();
    if (detail != NULL)
        goto missing_symbol;
    _Static_assert(sizeof(loader.luaopen_luv) == sizeof(symbol),
        "luaopen_luv pointer representation mismatch");
    memcpy(&loader.luaopen_luv, &symbol, sizeof(symbol));

    dlerror();
    symbol = dlsym(loader.handle, "luv_set_loop");
    detail = dlerror();
    if (detail != NULL)
        goto missing_symbol;
    _Static_assert(sizeof(loader.luv_set_loop) == sizeof(symbol),
        "luv_set_loop pointer representation mismatch");
    memcpy(&loader.luv_set_loop, &symbol, sizeof(symbol));
    return;

missing_symbol:
    snprintf(loader.error, sizeof(loader.error), "load '%.480s': %.480s",
        loader.path, detail);
    loader.status = ENOSYS;
    dlclose(loader.handle);
    loader.handle = NULL;
}

int
luv_loader_prepare(lua_State *L) {
    int error;

    if (L == NULL)
        return EINVAL;
    pthread_mutex_lock(&loader_lock);
    if (!loader.prepared) {
        loader.status = find_luv_so(L, loader.path, sizeof(loader.path));
        if (loader.status != 0)
            snprintf(loader.error, sizeof(loader.error),
                "luv.so not found in package.cpath");
        loader.prepared = true;
    }
    pthread_mutex_unlock(&loader_lock);

    error = pthread_once(&loader_once, initialize_loader);
    if (error == 0)
        error = loader.status;
    return error;
}

const char *
luv_loader_error(void) {
    return loader.error[0] == '\0' ? "unknown luv loader error" : loader.error;
}

static int
cache_luv_module(lua_State *L) {
    int module_index = lua_gettop(L);

    lua_getglobal(L, "package");
    if (!lua_istable(L, -1))
        goto invalid_package;
    lua_getfield(L, -1, "loaded");
    if (!lua_istable(L, -1))
        goto invalid_package;
    lua_pushvalue(L, module_index);
    lua_setfield(L, -2, "luv");
    lua_settop(L, module_index);
    return 0;

invalid_package:
    lua_settop(L, module_index);
    return EINVAL;
}

int
service_load_luv(lua_State *L, uv_loop_t *loop) {
    int top;
    int error;
    int result_count;

    if (L == NULL || loop == NULL)
        return EINVAL;
    error = luv_loader_prepare(L);
    if (error != 0) {
        log_error("could not initialize luv loader: %s", luv_loader_error());
        return error;
    }

    top = lua_gettop(L);
    loader.luv_set_loop(L, loop);
    lua_pushcfunction(L, loader.luaopen_luv);
    error = lua_pcall(L, 0, LUA_MULTRET, 0);
    if (error != LUA_OK) {
        log_error("could not initialize luv module: %s", lua_tostring(L, -1));
        lua_settop(L, top);
        return EINVAL;
    }
    result_count = lua_gettop(L) - top;
    if (result_count != 1 || !lua_istable(L, -1) ||
        cache_luv_module(L) != 0) {
        log_error("luaopen_luv did not return one module table");
        lua_settop(L, top);
        return EINVAL;
    }
    lua_settop(L, top);
    return 0;
}

#ifdef LUV_LOADER_TESTING
unsigned
luv_loader_initialization_count(void) {
    return loader.initialization_count;
}
#endif
