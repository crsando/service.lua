#ifndef SERVICE_LOADLUV_H
#define SERVICE_LOADLUV_H

#include <lua.h>
#include <uv.h>

int luv_loader_prepare(lua_State *L);
const char *luv_loader_error(void);
int service_load_luv(lua_State *L, uv_loop_t *loop);

#ifdef LUV_LOADER_TESTING
unsigned luv_loader_initialization_count(void);
#endif

#endif
