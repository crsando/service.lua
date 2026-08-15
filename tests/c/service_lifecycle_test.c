#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "service.h"

#define PRODUCERS 8

typedef struct join_args {
    service_t *service;
    atomic_bool done;
} join_args_t;

typedef struct send_args {
    service_pool_t *pool;
    atomic_bool *go;
    atomic_uint *ready;
    atomic_uint *attempts;
} send_args_t;

typedef struct start_args {
    service_t *service;
    int result;
} start_args_t;

static void *
join_service(void *data) {
    join_args_t *args = data;
    assert(service_join(args->service) == 0);
    atomic_store(&args->done, true);
    return NULL;
}

static void *
start_service(void *data) {
    start_args_t *args = data;
    args->result = service_start(args->service);
    return NULL;
}

static void
test_join_waits_for_pin(void) {
    service_pool_t *pool = service_pool_new();
    service_t *service = service_new(pool, "pinned", "return function() end",
        NULL, 16);
    service_t *pinned = NULL;
    join_args_t args = { .service = service };
    pthread_t thread;

    assert(pool != NULL && service != NULL);
    atomic_init(&args.done, false);
    assert(service_pool_pin(pool, service->id, &pinned) == SERVICE_SEND_OK);
    assert(pinned == service);
    assert(service_stop(service) == 0);
    assert(service_pool_pin(pool, service->id, &pinned) ==
        SERVICE_SEND_STOPPED);

    assert(pthread_create(&thread, NULL, join_service, &args) == 0);
    for (;;) {
        bool joining;
        pthread_mutex_lock(&service->state_lock);
        joining = service->joining;
        pthread_mutex_unlock(&service->state_lock);
        if (joining)
            break;
        sched_yield();
    }
    assert(!atomic_load(&args.done));
    service_unpin(service);
    assert(pthread_join(thread, NULL) == 0);
    assert(atomic_load(&args.done));
    assert(service_get_state(service) == SERVICE_FREED);
    service_pool_delete(pool);
}

static void *
send_until_stopped(void *data) {
    send_args_t *args = data;

    atomic_fetch_add(args->ready, 1);
    while (!atomic_load(args->go))
        sched_yield();

    for (;;) {
        message_t message = { .to = 0, .type = MESSAGE_REQUEST };
        service_send_result_t result;

        message.msg = malloc(1);
        assert(message.msg != NULL);
        message.sz = 1;
        atomic_fetch_add(args->attempts, 1);
        result = service_send(args->pool, &message);
        if (result != SERVICE_SEND_OK)
            message_dispose(&message);
        if (result == SERVICE_SEND_NOT_FOUND ||
            result == SERVICE_SEND_STOPPING ||
            result == SERVICE_SEND_STOPPED)
            break;
        if (result == SERVICE_SEND_FULL)
            sched_yield();
    }
    return NULL;
}

static void
test_send_stop_race(void) {
    service_pool_t *pool = service_pool_new();
    service_t *service = service_new(pool, "target",
        "return function(_) end", NULL, 64);
    pthread_t threads[PRODUCERS];
    send_args_t args;
    atomic_bool go;
    atomic_uint ready;
    atomic_uint attempts;

    assert(pool != NULL && service != NULL);
    assert(service_start(service) == 0);
    atomic_init(&go, false);
    atomic_init(&ready, 0);
    atomic_init(&attempts, 0);
    args = (send_args_t) {
        .pool = pool,
        .go = &go,
        .ready = &ready,
        .attempts = &attempts,
    };
    for (size_t i = 0; i < PRODUCERS; i++)
        assert(pthread_create(&threads[i], NULL, send_until_stopped,
            &args) == 0);
    while (atomic_load(&ready) != PRODUCERS)
        sched_yield();
    atomic_store(&go, true);
    while (atomic_load(&attempts) < 1000)
        sched_yield();

    assert(service_stop(service) == 0);
    assert(service_join(service) == 0);
    for (size_t i = 0; i < PRODUCERS; i++)
        assert(pthread_join(threads[i], NULL) == 0);
    assert(service_get_state(service) == SERVICE_FREED);
    service_pool_delete(pool);
}

static void
test_stop_while_starting(void) {
    service_pool_t *pool = service_pool_new();
    service_t *service = service_new(pool, "starting",
        "local t=os.clock()+0.05 repeat until os.clock()>=t "
        "return function() end", NULL, 16);
    start_args_t args = { .service = service };
    pthread_t thread;

    assert(pool != NULL && service != NULL);
    assert(pthread_create(&thread, NULL, start_service, &args) == 0);
    for (;;) {
        service_state_t state = service_get_state(service);
        assert(state != SERVICE_RUNNING);
        if (state == SERVICE_STARTING)
            break;
        sched_yield();
    }
    assert(service_stop(service) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(args.result == ECANCELED);
    assert(service_join(service) == 0);
    assert(service_get_state(service) == SERVICE_FREED);
    service_pool_delete(pool);
}

static void
test_luv_handles_close_before_join(void) {
    static const char source[] =
        "local uv=require 'luv' "
        "local timer=uv.new_timer() "
        "timer:start(60000,60000,function() end) "
        "local server=uv.new_tcp() "
        "return function() end";
    service_pool_t *pool = service_pool_new();
    service_t *service = service_new(pool, "luv", source, NULL, 16);

    assert(pool != NULL && service != NULL);
    assert(service_start(service) == 0);
    assert(uv_loop_alive(service_get_loop(service)) != 0);
    assert(service_stop(service) == 0);
    assert(service_join(service) == 0);
    assert(service_get_state(service) == SERVICE_FREED);
    assert(service_get_loop(service) == NULL);
    service_pool_delete(pool);
}

static void
test_pool_limits(void) {
    service_pool_t *pool = service_pool_new();

    assert(pool != NULL);
    assert(service_new(pool, "unique", "return function() end", NULL, 16)
        != NULL);
    assert(service_new(pool, "unique", "return function() end", NULL, 16)
        == NULL);
    for (size_t i = 1; i < MAX_SERVICES; i++)
        assert(service_new(pool, NULL, "return function() end", NULL, 16)
            != NULL);
    assert(pool->next_id == MAX_SERVICES);
    assert(service_new(pool, NULL, "return function() end", NULL, 16)
        == NULL);
    assert(pool->next_id == MAX_SERVICES);
    service_pool_delete(pool);
}

int
main(void) {
    test_join_waits_for_pin();
    test_send_stop_race();
    test_stop_while_starting();
    test_luv_handles_close_before_join();
    test_pool_limits();
    puts("service_lifecycle_test: ok");
    return 0;
}
