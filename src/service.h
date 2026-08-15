#ifndef SERVICE_SERVICE_H
#define SERVICE_SERVICE_H

#include <stdbool.h>
#include <pthread.h>

#include <lua.h>
#include <uv.h>

#include "mailbox.h"
#include "message.h"
#include "registry.h"

#define MAX_SERVICES 32
#define MAX_SERVICE_NAME_LEN 32
#define SERVICE_MAILBOX_DEFAULT_SIZE 1024
#define SERVICE_MAILBOX_MIN_SIZE 16
#define SERVICE_MAILBOX_MAX_SIZE 65536

typedef struct service service_t;
typedef struct service_pool service_pool_t;

typedef enum service_state {
    SERVICE_NEW = 0,
    SERVICE_STARTING,
    SERVICE_RUNNING,
    SERVICE_STOPPING,
    SERVICE_STOPPED,
    SERVICE_JOINED,
    SERVICE_FREED,
} service_state_t;

typedef enum service_send_result {
    SERVICE_SEND_OK = 0,
    SERVICE_SEND_FULL,
    SERVICE_SEND_NOT_FOUND,
    SERVICE_SEND_STOPPING,
    SERVICE_SEND_STOPPED,
} service_send_result_t;

struct service_pool {
    pthread_mutex_t lock;
    pthread_cond_t pins_changed;
    service_t *services[MAX_SERVICES];
    service_id_t next_id;
    registry_t *variables;
};

/* service_t is a stable handle; its runtime fields are released after join. */
struct service {
    service_pool_t *pool;
    service_id_t id;
    char name[MAX_SERVICE_NAME_LEN];
    bool routable;             /* protected by pool->lock */
    unsigned send_pins;        /* protected by pool->lock */

    pthread_mutex_t state_lock;
    pthread_cond_t state_changed;
    service_state_t state;
    bool stop_requested;
    bool start_done;
    bool thread_created;
    bool joining;
    bool thread_joined;
    int start_error;
    int join_error;

    pthread_t thread;
    char *source;
    void *config;
    mailbox_t *inbox;

    lua_State *L;
    int func_ref;
    uv_loop_t loop;
    uv_async_t inbox_async;
    uv_async_t control_async;
    bool loop_ready;
    bool inbox_async_ready;
    bool control_async_ready;
};

service_pool_t *service_pool_new(void);
void service_pool_delete(service_pool_t *pool);
void *service_pool_registry(service_pool_t *pool, const char *key, void *ptr);
service_t *service_pool_get_service(service_pool_t *pool, service_id_t id);
service_t *service_pool_lookup_service(service_pool_t *pool, const char *name);

service_t *service_new(service_pool_t *pool, const char *name,
    const char *source, void *config, size_t mailbox_size);
int service_start(service_t *service);
int service_stop(service_t *service);
int service_join(service_t *service);
int service_free(service_t *service);

service_send_result_t service_pool_pin(
    service_pool_t *pool, service_id_t id, service_t **out);
void service_unpin(service_t *service);
service_send_result_t service_send(
    service_pool_t *pool, const message_t *message);
bool service_recv(service_t *service, bool blocking, message_t *out);

service_state_t service_get_state(service_t *service);
uv_loop_t *service_get_loop(service_t *service);
uv_async_t *service_get_async(service_t *service);

#endif
