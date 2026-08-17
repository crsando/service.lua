#define LUA_LIB
#define LUAMOD_API LUALIB_API // back-port 5.1

#include <lua.h>
#include <lauxlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#include "uv.h"

#include "message.h"
#include "service.h"
#include "log.h"
#include "loadluv.h"
#include "lua-seri.h"

static int lservice_pool_new(lua_State *L) {
    service_pool_t * pool = service_pool_new();
    if (pool == NULL)
        return luaL_error(L, "could not create service pool");
    lua_pushlightuserdata(L, pool);
    return 1;
}

static int lservice_new(lua_State *L) {
    service_pool_t * pool = lua_touserdata(L, 1);
    const char * name = ( (lua_isnil(L,2)) ? NULL : luaL_checkstring(L, 2) );
	const char * source = luaL_checkstring(L, 3);
    void * config = lua_touserdata(L, 4);
    size_t mailbox_size = SERVICE_MAILBOX_DEFAULT_SIZE;

    if (lua_istable(L, 5)) {
        lua_getfield(L, 5, "mailbox_size");
        if (!lua_isnil(L, -1)) {
            lua_Integer value = luaL_checkinteger(L, -1);
            if (value < SERVICE_MAILBOX_MIN_SIZE || value > SERVICE_MAILBOX_MAX_SIZE)
                return luaL_error(L, "mailbox_size must be between %d and %d",
                    SERVICE_MAILBOX_MIN_SIZE, SERVICE_MAILBOX_MAX_SIZE);
            mailbox_size = (size_t)value;
        }
        lua_pop(L, 1);
    }

    service_t * s = service_new(pool, name, source, config, mailbox_size);
    if (s == NULL) {
        free(config);
        return luaL_error(L, "could not create service");
    }
    lua_pushlightuserdata(L, s);
    return 1;
}

static int lservice_lookup(lua_State *L) {
    service_t * s;
    service_pool_t * pool = lua_touserdata(L, 1);
    const char * name = ( (lua_isnil(L,2)) ? NULL : luaL_checkstring(L, 2) );
    s = service_pool_lookup_service(pool, name);
    if (s == NULL)
        return 0;
    lua_pushinteger(L, s->id);
    return 1;
}

static int lservice_start(lua_State *L) {
    service_t * s = lua_touserdata(L, 1);
    int ret = service_start(s);
    if (ret != 0) {
        if (service_get_state(s) >= SERVICE_STOPPING)
            service_join(s);
        return luaL_error(L, "SERVICE_START_FAILED: %d", ret);
    }
    lua_pushinteger(L, ret);
    return 1;
}

static int lservice_stop(lua_State *L) {
    service_t * s = lua_touserdata(L, 1);
    int ret = service_stop(s);
    if (ret != 0)
        return luaL_error(L, "could not stop service: %d", ret);
    lua_pushinteger(L, ret);
    return 1;
}

static int lservice_join(lua_State *L) {
    service_t * s = lua_touserdata(L, 1);
    int ret = service_join(s);
    if (ret != 0)
        return luaL_error(L, "could not join service: %d", ret);
    lua_pushinteger(L, ret);
    return 1;
}

static int lservice_get_uv_loop(lua_State *L) {
    service_t * s = lua_touserdata(L, 1);
    uv_loop_t *loop = service_get_loop(s);
    if (loop == NULL)
        return 0;
    lua_pushlightuserdata(L, loop);
    return 1;
}

static int lservice_get_id(lua_State *L) {
    service_t * s = lua_touserdata(L, 1);
    lua_pushinteger(L, s->id);
    return 1;
}



static int lservice_get_pool(lua_State *L) {
    service_t * s = lua_touserdata(L, 1);
    lua_pushlightuserdata(L, s->pool);
    return 1;
}

static int lservice_get_async(lua_State *L) {
    service_t * s = lua_touserdata(L, 1);
    uv_async_t *async = service_get_async(s);
    if (async == NULL)
        return 0;
    lua_pushlightuserdata(L, async);
    return 1;
}

static int lservice_get_addr(lua_State *L) {
    service_t * s = lua_touserdata(L, 1);
    lua_Integer value = luaL_checkinteger(L, 2);
    service_t *ret;

    if (s == NULL || value < 0 || (uint64_t)value >= MAX_SERVICES) {
        lua_pushnil(L);
        lua_pushliteral(L, "SERVICE_NOT_FOUND");
        return 2;
    }
    ret = service_pool_get_service(s->pool, (service_id_t)value);
    if (ret == NULL) {
        lua_pushnil(L);
        lua_pushliteral(L, "SERVICE_NOT_FOUND");
        return 2;
    }
    lua_pushlightuserdata(L, ret);
    return 1;
}

// message related utilities

// from, to, session, type, msg, sz
static uint32_t check_uint32(lua_State *L, int index, const char *field) {
    lua_Integer value = luaL_checkinteger(L, index);
    if (value < 0 || (uint64_t)value > UINT32_MAX)
        luaL_error(L, "%s must be a uint32", field);
    return (uint32_t)value;
}

static inline void compose_message(lua_State *L, message_t *message) {
	message->from = check_uint32(L, 2, "from");
	message->to = check_uint32(L, 3, "to");
	message->session = check_uint32(L, 4, "session");
	message->type = luaL_checkinteger(L, 5);
	if (lua_isnoneornil(L, 6)) {
		message->msg = NULL;
		message->sz = 0;
	} else {
		luaL_checktype(L, 6, LUA_TLIGHTUSERDATA);
		message->msg = lua_touserdata(L, 6);
		lua_Integer size = luaL_checkinteger(L, 7);
		if (size < 0)
			luaL_error(L, "message size must be non-negative");
		message->sz = (size_t)size;
	}
}

/*
    lightuserdata pool
    integer from
	integer to
	integer session
	integer type
	pointer message
	integer sz
 */
static int lservice_send_message(lua_State *L) {
	// if (!lua_isyieldable(L)) {
	// 	return luaL_error(L, "Can't send message in none-yieldable context");
	// }


    luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
    service_pool_t * pool = lua_touserdata(L, 1);

    // parse stack 2 -> 7
    message_t message;
    compose_message(L, &message);
    service_send_result_t result = service_send(pool, &message);
    if (result != SERVICE_SEND_OK) {
        const char *error = "SERVICE_STOPPED";

        message_dispose(&message);
        if (result == SERVICE_SEND_FULL)
            error = "MAILBOX_FULL";
        else if (result == SERVICE_SEND_NOT_FOUND)
            error = "SERVICE_NOT_FOUND";
        else if (result == SERVICE_SEND_STOPPING)
            error = "SERVICE_STOPPING";
        lua_pushnil(L);
        lua_pushstring(L, error);
        return 2;
    }

    lua_pushboolean(L, 1);
	return 1;
}

static int lservice_recv_message(lua_State *L) {
    luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
    service_t * s = lua_touserdata(L, 1);

    luaL_checktype(L, 2, LUA_TBOOLEAN);
    bool blocking = lua_toboolean(L, 2);

    message_t message;

    if(service_recv(s, blocking, &message)) {
        lua_pushinteger(L, message.from);
        lua_pushinteger(L, message.to);
        lua_pushinteger(L, message.session);
        lua_pushinteger(L, message.type);
        lua_pushlightuserdata(L, message.msg);
        lua_pushinteger(L, message.sz);
        return 6;
    }
    else {
        return 0;
    }
}

static int lservice_log_error(lua_State *L) {
    luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
    service_t *s = lua_touserdata(L, 1);
    const char *message = luaL_checkstring(L, 2);

    log_error("service %u handler: %s", s->id, message);
    return 0;
}

static int
luaseri_remove(lua_State *L) {
	if (lua_isnoneornil(L, 1))
		return 0;
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);
	void * data = lua_touserdata(L, 1);
	size_t sz = luaL_checkinteger(L, 2);
	(void)sz;
	free(data);
	return 0;
}

// open lua library
LUAMOD_API int luaopen_lservice3_c(lua_State *L) {
	if (luv_loader_prepare(L) != 0)
		return luaL_error(L, "could not initialize luv loader: %s",
			luv_loader_error());
	// luaL_checkversion(L);
	luaL_Reg l[] = {
        // pool
		{ "_pool_new", lservice_pool_new },
		{ "_lookup", lservice_lookup },
		{ "_get_pool", lservice_get_pool },
		{ "_get_async", lservice_get_async },
		{ "_get_addr", lservice_get_addr },
		{ "_get_uv_loop", lservice_get_uv_loop },

        // service
		{ "_new", lservice_new },
		{ "_start", lservice_start },
		{ "_stop", lservice_stop },
		{ "_join", lservice_join },
		{ "_get_id", lservice_get_id },
		{ "_send_message", lservice_send_message },
		{ "_recv_message", lservice_recv_message },
		{ "_log_error", lservice_log_error },

        // serialization components
		{ "remove", luaseri_remove },
		{ "pack", luaseri_pack },
		{ "unpack", luaseri_unpack },
		{ "unpack_remove", luaseri_unpack_remove },

        // end
		{ NULL, NULL },
	};
	luaL_newlib(L, l);
	return 1;
}
