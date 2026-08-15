#include "service.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lualib.h"

#include "log.h"
#include "loadluv.h"

static void service_control_cb(uv_async_t *handle);

static void
service_async_cb(uv_async_t *handle) {
    service_t *service = handle->data;
    int top;

    if (service == NULL || service_get_state(service) != SERVICE_RUNNING)
        return;
    if (service->L == NULL || service->func_ref == LUA_NOREF ||
        service->func_ref == LUA_REFNIL)
        return;

    top = lua_gettop(service->L);
    lua_rawgeti(service->L, LUA_REGISTRYINDEX, service->func_ref);
    lua_pushliteral(service->L, "msg");
    if (lua_pcall(service->L, 1, 0, 0) != LUA_OK)
        log_error("service %u handler: %s", service->id,
            lua_tostring(service->L, -1));
    lua_settop(service->L, top);
}

service_pool_t *
service_pool_new(void) {
    service_pool_t *pool = calloc(1, sizeof(*pool));

    if (pool == NULL)
        return NULL;
    if (pthread_mutex_init(&pool->lock, NULL) != 0) {
        free(pool);
        return NULL;
    }
    if (pthread_cond_init(&pool->pins_changed, NULL) != 0) {
        pthread_mutex_destroy(&pool->lock);
        free(pool);
        return NULL;
    }
    return pool;
}

service_t *
service_pool_get_service(service_pool_t *pool, service_id_t id) {
    service_t *service = NULL;

    if (pool == NULL || id >= MAX_SERVICES)
        return NULL;
    pthread_mutex_lock(&pool->lock);
    service = pool->services[id];
    pthread_mutex_unlock(&pool->lock);
    return service;
}

service_t *
service_pool_lookup_service(service_pool_t *pool, const char *name) {
    service_t *service = NULL;

    if (pool == NULL || name == NULL)
        return NULL;
    pthread_mutex_lock(&pool->lock);
    for (service_id_t id = 0; id < pool->next_id; id++) {
        service_t *candidate = pool->services[id];
        if (candidate != NULL && candidate->routable &&
            strcmp(candidate->name, name) == 0) {
            service = candidate;
            break;
        }
    }
    pthread_mutex_unlock(&pool->lock);
    return service;
}

void *
service_pool_registry(service_pool_t *pool, const char *key, void *ptr) {
    void *data = NULL;

    if (pool == NULL || key == NULL)
        return NULL;
    pthread_mutex_lock(&pool->lock);
    if (ptr != NULL) {
        registry_t *entry = registry_put(&pool->variables, key, ptr);
        data = entry == NULL ? NULL : entry->ptr;
    } else if (pool->variables != NULL) {
        registry_t *entry = registry_get(&pool->variables, key);
        data = entry == NULL ? NULL : entry->ptr;
    }
    pthread_mutex_unlock(&pool->lock);
    return data;
}

service_state_t
service_get_state(service_t *service) {
    service_state_t state;

    if (service == NULL)
        return SERVICE_FREED;
    pthread_mutex_lock(&service->state_lock);
    state = service->state;
    pthread_mutex_unlock(&service->state_lock);
    return state;
}

uv_loop_t *
service_get_loop(service_t *service) {
    uv_loop_t *loop;

    if (service == NULL)
        return NULL;
    pthread_mutex_lock(&service->state_lock);
    loop = service->loop_ready ? &service->loop : NULL;
    pthread_mutex_unlock(&service->state_lock);
    return loop;
}

uv_async_t *
service_get_async(service_t *service) {
    uv_async_t *async;

    if (service == NULL)
        return NULL;
    pthread_mutex_lock(&service->state_lock);
    async = service->inbox_async_ready ? &service->inbox_async : NULL;
    pthread_mutex_unlock(&service->state_lock);
    return async;
}

static service_send_result_t
inactive_send_result(service_t *service) {
    service_state_t state = service_get_state(service);
    return state < SERVICE_STOPPED ? SERVICE_SEND_STOPPING :
        SERVICE_SEND_STOPPED;
}

service_send_result_t
service_pool_pin(service_pool_t *pool, service_id_t id, service_t **out) {
    service_t *service;

    if (out == NULL)
        return SERVICE_SEND_NOT_FOUND;
    *out = NULL;
    if (pool == NULL || id >= MAX_SERVICES)
        return SERVICE_SEND_NOT_FOUND;

    pthread_mutex_lock(&pool->lock);
    service = pool->services[id];
    if (service != NULL && service->routable) {
        service->send_pins++;
        *out = service;
    }
    pthread_mutex_unlock(&pool->lock);

    if (service == NULL)
        return SERVICE_SEND_NOT_FOUND;
    return *out == NULL ? inactive_send_result(service) : SERVICE_SEND_OK;
}

void
service_unpin(service_t *service) {
    service_pool_t *pool;

    if (service == NULL || service->pool == NULL)
        return;
    pool = service->pool;
    pthread_mutex_lock(&pool->lock);
    if (service->send_pins > 0) {
        service->send_pins--;
        if (service->send_pins == 0)
            pthread_cond_broadcast(&pool->pins_changed);
    }
    pthread_mutex_unlock(&pool->lock);
}

static void
service_retire(service_t *service) {
    service_pool_t *pool = service->pool;

    pthread_mutex_lock(&pool->lock);
    service->routable = false;
    pthread_mutex_unlock(&pool->lock);
}

static void
service_wait_pins(service_t *service) {
    service_pool_t *pool = service->pool;

    pthread_mutex_lock(&pool->lock);
    while (service->send_pins != 0)
        pthread_cond_wait(&pool->pins_changed, &pool->lock);
    pthread_mutex_unlock(&pool->lock);
}

int
lua_loadfile_as_buffer(lua_State *L, const char *at_name) {
    const char *path;
    FILE *file;
    char *buffer;
    long length;
    size_t read_length;
    int status;

    if (at_name == NULL || at_name[0] != '@' || at_name[1] == '\0') {
        lua_pushliteral(L, "source filename must start with '@'");
        return LUA_ERRFILE;
    }
    path = at_name + 1;
    file = fopen(path, "rb");
    if (file == NULL) {
        lua_pushfstring(L, "cannot open file '%s'", path);
        return LUA_ERRFILE;
    }
    if (fseek(file, 0, SEEK_END) != 0 || (length = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        lua_pushfstring(L, "cannot read file '%s'", path);
        return LUA_ERRFILE;
    }
    buffer = malloc(length == 0 ? 1 : (size_t)length);
    if (buffer == NULL) {
        fclose(file);
        return LUA_ERRMEM;
    }
    read_length = fread(buffer, 1, (size_t)length, file);
    fclose(file);
    if (read_length != (size_t)length) {
        free(buffer);
        lua_pushfstring(L, "cannot read file '%s'", path);
        return LUA_ERRFILE;
    }
    status = luaL_loadbuffer(L, buffer, (size_t)length, at_name);
    free(buffer);
    return status;
}

static int
service_init_loop(service_t *service) {
    int error = uv_loop_init(&service->loop);

    if (error != 0)
        return error;
    pthread_mutex_lock(&service->state_lock);
    service->loop_ready = true;
    pthread_mutex_unlock(&service->state_lock);

    error = uv_async_init(&service->loop, &service->inbox_async,
        service_async_cb);
    if (error != 0)
        return error;
    service->inbox_async.data = service;
    pthread_mutex_lock(&service->state_lock);
    service->inbox_async_ready = true;
    pthread_mutex_unlock(&service->state_lock);

    error = uv_async_init(&service->loop, &service->control_async,
        service_control_cb);
    if (error != 0)
        return error;
    service->control_async.data = service;
    pthread_mutex_lock(&service->state_lock);
    service->control_async_ready = true;
    pthread_mutex_unlock(&service->state_lock);
    return 0;
}

static int
service_init_lua(service_t *service) {
    lua_State *L = luaL_newstate();
    int argument_count = 1;

    if (L == NULL)
        return ENOMEM;
    service->L = L;
    luaL_openlibs(L);

    if ((service->source[0] == '@' ?
            lua_loadfile_as_buffer(L, service->source) :
            luaL_loadstring(L, service->source)) != LUA_OK) {
        log_error("service %u load: %s", service->id,
            lua_tostring(L, -1));
        return EINVAL;
    }
    if (service_load_luv(L, &service->loop) < 0)
        return EINVAL;

    lua_pushlightuserdata(L, service);
    if (service->config != NULL) {
        lua_pushlightuserdata(L, service->config);
        argument_count++;
    }
    if (lua_pcall(L, argument_count, 1, 0) != LUA_OK) {
        free(service->config);
        service->config = NULL;
        log_error("service %u init: %s", service->id,
            lua_tostring(L, -1));
        return EINVAL;
    }
    free(service->config);
    service->config = NULL;
    if (!lua_isfunction(L, -1)) {
        log_error("service %u source did not return a handler", service->id);
        return EINVAL;
    }
    service->func_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    return 0;
}

static void
service_drain_mailbox(service_t *service) {
    message_t message;

    while (mailbox_try_pop(service->inbox, &message))
        message_dispose(&message);
}

typedef struct luv_close_context {
    service_t *service;
    int error;
} luv_close_context_t;

static int
close_luv_handle(lua_State *L) {
    luv_close_context_t *context =
        lua_touserdata(L, lua_upvalueindex(3));
    bool closing;

    lua_pushvalue(L, lua_upvalueindex(1));
    lua_pushvalue(L, 1);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        log_error("service %u inspect luv handle: %s", context->service->id,
            lua_tostring(L, -1));
        context->error = EINVAL;
        lua_pop(L, 1);
        return 0;
    }
    closing = lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (closing)
        return 0;

    lua_pushvalue(L, lua_upvalueindex(2));
    lua_pushvalue(L, 1);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        log_error("service %u close luv handle: %s", context->service->id,
            lua_tostring(L, -1));
        context->error = EINVAL;
        lua_pop(L, 1);
    }
    return 0;
}

static int
service_close_luv_handles(service_t *service) {
    lua_State *L = service->L;
    luv_close_context_t context = { .service = service };
    int top;
    int luv_index;

    if (L == NULL)
        return 0;
    top = lua_gettop(L);
    lua_getglobal(L, "package");
    if (!lua_istable(L, -1))
        goto unavailable;
    lua_getfield(L, -1, "loaded");
    if (!lua_istable(L, -1))
        goto unavailable;
    lua_getfield(L, -1, "luv");
    if (!lua_istable(L, -1))
        goto unavailable;
    luv_index = lua_gettop(L);

    lua_getfield(L, luv_index, "walk");
    if (!lua_isfunction(L, -1))
        goto unavailable;
    lua_getfield(L, luv_index, "is_closing");
    if (!lua_isfunction(L, -1))
        goto unavailable;
    lua_getfield(L, luv_index, "close");
    if (!lua_isfunction(L, -1))
        goto unavailable;
    lua_pushlightuserdata(L, &context);
    lua_pushcclosure(L, close_luv_handle, 3);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        log_error("service %u walk luv handles: %s", service->id,
            lua_tostring(L, -1));
        context.error = EINVAL;
    }
    lua_settop(L, top);
    return context.error;

unavailable:
    lua_settop(L, top);
    return ENOENT;
}

static bool
service_runtime_handles_closed(service_t *service) {
    bool closed;

    pthread_mutex_lock(&service->state_lock);
    closed = !service->inbox_async_ready && !service->control_async_ready;
    pthread_mutex_unlock(&service->state_lock);
    return closed;
}

static void
service_runtime_handle_closed(uv_handle_t *handle) {
    service_t *service = handle->data;
    bool closed;

    pthread_mutex_lock(&service->state_lock);
    if (handle == (uv_handle_t *)&service->inbox_async)
        service->inbox_async_ready = false;
    else if (handle == (uv_handle_t *)&service->control_async)
        service->control_async_ready = false;
    closed = !service->inbox_async_ready && !service->control_async_ready;
    pthread_mutex_unlock(&service->state_lock);

    /* Some luv versions assume uv.walk never sees foreign native handles. */
    if (closed)
        (void)service_close_luv_handles(service);
}

static void
service_close_runtime_handles(service_t *service) {
    uv_handle_t *handle;

    if (service->inbox_async_ready) {
        handle = (uv_handle_t *)&service->inbox_async;
        if (!uv_is_closing(handle))
            uv_close(handle, service_runtime_handle_closed);
    }
    if (service->control_async_ready) {
        handle = (uv_handle_t *)&service->control_async;
        if (!uv_is_closing(handle))
            uv_close(handle, service_runtime_handle_closed);
    }
}

static void
service_prepare_shutdown(service_t *service) {
    service_retire(service);
    mailbox_close(service->inbox);
    service_wait_pins(service);
    service_drain_mailbox(service);
}

static void
service_control_cb(uv_async_t *handle) {
    service_t *service = handle->data;
    bool stopping;

    pthread_mutex_lock(&service->state_lock);
    stopping = service->stop_requested;
    pthread_mutex_unlock(&service->state_lock);
    if (!stopping)
        return;

    service_prepare_shutdown(service);
    service_close_runtime_handles(service);
}

static void
service_finish_thread(service_t *service) {
    bool loop_ready;
    int error;

    pthread_mutex_lock(&service->state_lock);
    if (service->state < SERVICE_STOPPING)
        service->state = SERVICE_STOPPING;
    loop_ready = service->loop_ready;
    pthread_mutex_unlock(&service->state_lock);

    service_prepare_shutdown(service);
    if (loop_ready) {
        for (;;) {
            service_close_runtime_handles(service);
            if (service_runtime_handles_closed(service))
                (void)service_close_luv_handles(service);
            uv_run(&service->loop, UV_RUN_DEFAULT);
            error = uv_loop_close(&service->loop);
            if (error == 0)
                break;
            if (error != UV_EBUSY)
                log_error("service %u could not close loop: %s", service->id,
                    uv_strerror(error));
        }
    }
    if (service->L != NULL) {
        lua_close(service->L);
        service->L = NULL;
        service->func_ref = LUA_NOREF;
    }

    pthread_mutex_lock(&service->state_lock);
    service->loop_ready = false;
    service->inbox_async_ready = false;
    service->control_async_ready = false;
    service->state = SERVICE_STOPPED;
    pthread_cond_broadcast(&service->state_changed);
    pthread_mutex_unlock(&service->state_lock);
}

static void *
service_thread_main(void *data) {
    service_t *service = data;
    bool stop_requested;
    bool running;
    int error = service_init_loop(service);

    pthread_mutex_lock(&service->state_lock);
    stop_requested = service->stop_requested;
    pthread_mutex_unlock(&service->state_lock);
    if (error == 0 && !stop_requested)
        error = service_init_lua(service);

    pthread_mutex_lock(&service->state_lock);
    stop_requested = service->stop_requested;
    if (error == 0 && !stop_requested) {
        service->state = SERVICE_RUNNING;
        service->start_error = 0;
        running = true;
    } else {
        service->state = SERVICE_STOPPING;
        service->start_error = error == 0 ? ECANCELED : error;
        running = false;
    }
    service->start_done = true;
    pthread_cond_broadcast(&service->state_changed);
    pthread_mutex_unlock(&service->state_lock);

    if (running) {
        /* Covers messages accepted before inbox_async was initialized. */
        uv_async_send(&service->inbox_async);
        uv_run(&service->loop, UV_RUN_DEFAULT);
    }
    service_finish_thread(service);
    return NULL;
}

service_t *
service_new(service_pool_t *pool, const char *name, const char *source,
    void *config, size_t mailbox_size) {
    service_t *service;
    size_t source_length;

    if (pool == NULL || source == NULL ||
        mailbox_size < SERVICE_MAILBOX_MIN_SIZE ||
        mailbox_size > SERVICE_MAILBOX_MAX_SIZE ||
        (name != NULL && strlen(name) >= MAX_SERVICE_NAME_LEN))
        return NULL;

    service = calloc(1, sizeof(*service));
    if (service == NULL)
        return NULL;
    service->pool = pool;
    service->config = config;
    service->func_ref = LUA_NOREF;
    service->state = SERVICE_NEW;

    if (pthread_mutex_init(&service->state_lock, NULL) != 0)
        goto fail_service;
    if (pthread_cond_init(&service->state_changed, NULL) != 0)
        goto fail_mutex;
    service->inbox = mailbox_new(mailbox_size);
    if (service->inbox == NULL)
        goto fail_cond;
    source_length = strlen(source);
    service->source = malloc(source_length + 1);
    if (service->source == NULL)
        goto fail_mailbox;
    memcpy(service->source, source, source_length + 1);
    if (name != NULL)
        memcpy(service->name, name, strlen(name) + 1);

    pthread_mutex_lock(&pool->lock);
    if (pool->next_id >= MAX_SERVICES)
        goto fail_register;
    if (service->name[0] != '\0') {
        for (service_id_t id = 0; id < pool->next_id; id++) {
            service_t *other = pool->services[id];
            if (other != NULL && other->routable &&
                strcmp(other->name, service->name) == 0)
                goto fail_register;
        }
    }
    service->id = pool->next_id++;
    service->routable = true;
    pool->services[service->id] = service;
    pthread_mutex_unlock(&pool->lock);
    return service;

fail_register:
    pthread_mutex_unlock(&pool->lock);
    free(service->source);
fail_mailbox:
    mailbox_delete(service->inbox);
fail_cond:
    pthread_cond_destroy(&service->state_changed);
fail_mutex:
    pthread_mutex_destroy(&service->state_lock);
fail_service:
    free(service);
    return NULL;
}

int
service_start(service_t *service) {
    int error;

    if (service == NULL)
        return EINVAL;
    pthread_mutex_lock(&service->state_lock);
    if (service->state != SERVICE_NEW) {
        pthread_mutex_unlock(&service->state_lock);
        return EALREADY;
    }
    service->state = SERVICE_STARTING;
    error = pthread_create(&service->thread, NULL, service_thread_main, service);
    if (error != 0) {
        service->state = SERVICE_STOPPED;
        service->start_done = true;
        service->start_error = error;
        pthread_cond_broadcast(&service->state_changed);
        pthread_mutex_unlock(&service->state_lock);
        service_retire(service);
        mailbox_close(service->inbox);
        return error;
    }
    service->thread_created = true;
    while (!service->start_done)
        pthread_cond_wait(&service->state_changed, &service->state_lock);
    error = service->start_error;
    pthread_mutex_unlock(&service->state_lock);
    return error;
}

int
service_stop(service_t *service) {
    uv_async_t *control = NULL;
    mailbox_t *inbox = NULL;
    bool first_request = false;

    if (service == NULL)
        return EINVAL;
    service_retire(service);

    pthread_mutex_lock(&service->state_lock);
    switch (service->state) {
    case SERVICE_NEW:
        service->stop_requested = true;
        service->start_done = true;
        service->start_error = ECANCELED;
        service->state = SERVICE_STOPPED;
        inbox = service->inbox;
        break;
    case SERVICE_STARTING:
    case SERVICE_RUNNING:
        first_request = !service->stop_requested;
        service->stop_requested = true;
        service->state = SERVICE_STOPPING;
        inbox = service->inbox;
        if (first_request && service->control_async_ready)
            control = &service->control_async;
        break;
    case SERVICE_STOPPING:
    case SERVICE_STOPPED:
    case SERVICE_JOINED:
    case SERVICE_FREED:
        break;
    }
    pthread_cond_broadcast(&service->state_changed);
    pthread_mutex_unlock(&service->state_lock);

    if (inbox != NULL)
        mailbox_close(inbox);
    if (control != NULL && uv_async_send(control) != 0)
        log_error("could not request stop for service %u", service->id);
    return 0;
}

service_send_result_t
service_send(service_pool_t *pool, const message_t *message) {
    service_t *service;
    service_send_result_t result;
    mailbox_result_t mailbox_result;
    bool notify;
    bool async_ready;
    int notify_error = 0;

    if (message == NULL)
        return SERVICE_SEND_NOT_FOUND;
    result = service_pool_pin(pool, message->to, &service);
    if (result != SERVICE_SEND_OK)
        return result;

    mailbox_result = mailbox_try_push(service->inbox, message, &notify);
    if (mailbox_result == MAILBOX_OK && notify) {
        pthread_mutex_lock(&service->state_lock);
        async_ready = service->inbox_async_ready;
        pthread_mutex_unlock(&service->state_lock);
        if (async_ready)
            notify_error = uv_async_send(&service->inbox_async);
    }

    if (mailbox_result == MAILBOX_FULL)
        result = SERVICE_SEND_FULL;
    else if (mailbox_result == MAILBOX_CLOSED)
        result = inactive_send_result(service);
    service_unpin(service);

    if (notify_error != 0) {
        log_error("could not notify service %u", service->id);
        service_stop(service);
    }
    return result;
}

bool
service_recv(service_t *service, bool blocking, message_t *out) {
    (void)blocking;
    if (service == NULL || out == NULL ||
        service_get_state(service) != SERVICE_RUNNING)
        return false;
    return mailbox_try_pop(service->inbox, out);
}

int
service_free(service_t *service) {
    mailbox_t *inbox;
    char *source;
    void *config;

    if (service == NULL)
        return EINVAL;
    service_retire(service);
    service_wait_pins(service);

    pthread_mutex_lock(&service->state_lock);
    if (service->state != SERVICE_JOINED) {
        pthread_mutex_unlock(&service->state_lock);
        return EBUSY;
    }
    inbox = service->inbox;
    source = service->source;
    config = service->config;
    service->inbox = NULL;
    service->source = NULL;
    service->config = NULL;
    service->state = SERVICE_FREED;
    pthread_cond_broadcast(&service->state_changed);
    pthread_mutex_unlock(&service->state_lock);

    mailbox_delete(inbox);
    free(source);
    free(config);
    return 0;
}

int
service_join(service_t *service) {
    bool has_thread;
    int error = 0;

    if (service == NULL)
        return EINVAL;
    pthread_mutex_lock(&service->state_lock);
    has_thread = service->thread_created;
    if (has_thread && pthread_equal(pthread_self(), service->thread)) {
        pthread_mutex_unlock(&service->state_lock);
        return EDEADLK;
    }
    while (service->joining)
        pthread_cond_wait(&service->state_changed, &service->state_lock);
    if (service->thread_joined || service->state == SERVICE_FREED) {
        error = service->join_error;
        pthread_mutex_unlock(&service->state_lock);
        return error;
    }
    if (!has_thread && service->state != SERVICE_STOPPED) {
        pthread_mutex_unlock(&service->state_lock);
        return EINVAL;
    }
    service->joining = true;
    pthread_mutex_unlock(&service->state_lock);

    if (has_thread)
        error = pthread_join(service->thread, NULL);

    pthread_mutex_lock(&service->state_lock);
    service->join_error = error;
    if (error == 0) {
        service->thread_joined = true;
        service->state = SERVICE_JOINED;
    }
    pthread_mutex_unlock(&service->state_lock);
    if (error == 0)
        error = service_free(service);

    pthread_mutex_lock(&service->state_lock);
    service->joining = false;
    pthread_cond_broadcast(&service->state_changed);
    pthread_mutex_unlock(&service->state_lock);
    return error;
}

void
service_pool_delete(service_pool_t *pool) {
    if (pool == NULL)
        return;
    for (service_id_t id = 0; id < pool->next_id; id++)
        service_stop(pool->services[id]);
    for (service_id_t id = 0; id < pool->next_id; id++) {
        int error = service_join(pool->services[id]);
        if (error != 0) {
            log_error("could not join service %u during pool delete: %d",
                id, error);
            return;
        }
    }
    for (service_id_t id = 0; id < pool->next_id; id++) {
        service_t *service = pool->services[id];
        pthread_cond_destroy(&service->state_changed);
        pthread_mutex_destroy(&service->state_lock);
        free(service);
    }
    registry_clear(&pool->variables);
    pthread_cond_destroy(&pool->pins_changed);
    pthread_mutex_destroy(&pool->lock);
    free(pool);
}
