#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "mailbox.h"

#define MESSAGES_PER_PRODUCER 4000

typedef struct producer_args {
    mailbox_t *box;
    uint32_t id;
} producer_args_t;

static message_t
make_message(uint32_t producer, uint32_t sequence) {
    return (message_t) {
        .from = producer,
        .session = sequence,
        .type = MESSAGE_REQUEST,
    };
}

static void *
produce(void *data) {
    producer_args_t *args = data;

    for (uint32_t i = 0; i < MESSAGES_PER_PRODUCER; i++) {
        message_t message = make_message(args->id, i);
        mailbox_result_t result;
        bool notify;

        do {
            result = mailbox_try_push(args->box, &message, &notify);
            if (result == MAILBOX_FULL)
                sched_yield();
        } while (result == MAILBOX_FULL);
        assert(result == MAILBOX_OK);
    }
    return NULL;
}

static void
test_schedule_and_close(void) {
    mailbox_t *box = mailbox_new(1);
    message_t first = make_message(0, 1);
    message_t second = make_message(0, 2);
    message_t rejected;
    message_t out;
    bool notify;

    assert(box != NULL);
    assert(mailbox_try_push(box, &first, &notify) == MAILBOX_OK && notify);
    first.session = 99;

    // A full mailbox grows instead of rejecting; it is already scheduled.
    assert(mailbox_try_push(box, &second, &notify) == MAILBOX_OK && !notify);
    assert(mailbox_capacity(box) == 2);

    assert(mailbox_try_pop(box, &out) && out.session == 1);
    assert(mailbox_try_pop(box, &out) && out.session == 2);

    first = make_message(0, 3);
    assert(mailbox_try_push(box, &first, &notify) == MAILBOX_OK && !notify);
    assert(mailbox_try_pop(box, &out) && out.session == 3);
    assert(!mailbox_try_pop(box, &out));

    first = make_message(0, 4);
    assert(mailbox_try_push(box, &first, &notify) == MAILBOX_OK && notify);
    mailbox_close(box);
    assert(mailbox_try_pop(box, &out) && out.session == 4);

    rejected = make_message(0, 5);
    rejected.msg = malloc(1);
    assert(rejected.msg != NULL);
    assert(mailbox_try_push(box, &rejected, &notify) == MAILBOX_CLOSED && !notify);
    message_dispose(&rejected);
    mailbox_delete(box);

    box = mailbox_new(1);
    first = make_message(0, 6);
    first.msg = malloc(1);
    first.sz = 1;
    assert(box != NULL && first.msg != NULL);
    assert(mailbox_try_push(box, &first, &notify) == MAILBOX_OK);
    mailbox_delete(box);
}

static void
test_non_power_of_two_capacity(void) {
    mailbox_t *box = mailbox_new(3);
    message_t message;
    message_t out;
    bool notify;

    assert(box != NULL);
    for (uint32_t i = 0; i < 3; i++) {
        message = make_message(0, i);
        assert(mailbox_try_push(box, &message, &notify) == MAILBOX_OK);
        assert(notify == (i == 0));
    }
    assert(mailbox_try_pop(box, &out) && out.session == 0);

    message = make_message(0, 3);
    assert(mailbox_try_push(box, &message, &notify) == MAILBOX_OK && !notify);
    for (uint32_t i = 1; i < 4; i++)
        assert(mailbox_try_pop(box, &out) && out.session == i);
    assert(!mailbox_try_pop(box, &out));
    mailbox_delete(box);
}

static void
test_batch_schedule(void) {
    mailbox_t *box = mailbox_new(256);
    message_t message;
    message_t out;
    bool notify;

    assert(box != NULL);
    for (uint32_t i = 0; i < 256; i++) {
        message = make_message(0, i);
        assert(mailbox_try_push(box, &message, &notify) == MAILBOX_OK);
        assert(notify == (i == 0));
    }
    for (uint32_t i = 0; i < 256; i++) {
        assert(mailbox_try_pop(box, &out));
        assert(out.session == i);
    }
    assert(!mailbox_finish_batch(box));

    message = make_message(0, 256);
    assert(mailbox_try_push(box, &message, &notify) == MAILBOX_OK && notify);
    assert(mailbox_try_pop(box, &out) && out.session == 256);
    assert(!mailbox_finish_batch(box));
    mailbox_delete(box);

    box = mailbox_new(257);
    assert(box != NULL);
    for (uint32_t i = 0; i < 257; i++) {
        message = make_message(0, i);
        assert(mailbox_try_push(box, &message, &notify) == MAILBOX_OK);
        assert(notify == (i == 0));
    }
    for (uint32_t i = 0; i < 256; i++) {
        assert(mailbox_try_pop(box, &out));
        assert(out.session == i);
    }
    assert(mailbox_finish_batch(box));

    assert(mailbox_try_pop(box, &out) && out.session == 256);
    message = make_message(0, 257);
    assert(mailbox_try_push(box, &message, &notify) == MAILBOX_OK && !notify);
    assert(mailbox_try_pop(box, &out) && out.session == 257);
    assert(!mailbox_finish_batch(box));
    mailbox_delete(box);
}

// Growth keeps FIFO order even when the ring has wrapped around.
static void
test_growth(void) {
    mailbox_t *box = mailbox_new(4);
    message_t message;
    message_t out;
    bool notify;
    uint32_t next_in = 0, next_out = 0;

    assert(box != NULL);
    for (int i = 0; i < 3; i++) {
        message = make_message(0, next_in++);
        assert(mailbox_try_push(box, &message, &notify) == MAILBOX_OK);
    }
    assert(mailbox_try_pop(box, &out) && out.session == next_out++);
    assert(mailbox_try_pop(box, &out) && out.session == next_out++);
    while (next_in < 1000) {
        message = make_message(0, next_in++);
        assert(mailbox_try_push(box, &message, &notify) == MAILBOX_OK);
    }
    assert(mailbox_capacity(box) == 1024);
    while (mailbox_try_pop(box, &out))
        assert(out.session == next_out++);
    assert(next_out == 1000);
    mailbox_delete(box);
}

// Overload is reported once past the initial capacity, then again only past
// each doubled threshold, and the threshold resets once the mailbox drains.
static void
test_overload(void) {
    mailbox_t *box = mailbox_new(16);
    message_t message;
    message_t out;
    bool notify;

    assert(box != NULL);
    for (uint32_t i = 0; i < 100; i++) {
        message = make_message(0, i);
        assert(mailbox_try_push(box, &message, &notify) == MAILBOX_OK);
    }
    assert(mailbox_overload(box) == 0);
    assert(mailbox_try_pop(box, &out));
    assert(mailbox_overload(box) == 99);
    assert(mailbox_overload(box) == 0);
    assert(mailbox_try_pop(box, &out));
    assert(mailbox_overload(box) == 0);
    while (mailbox_try_pop(box, &out))
        ;
    for (uint32_t i = 0; i < 20; i++) {
        message = make_message(0, i);
        assert(mailbox_try_push(box, &message, &notify) == MAILBOX_OK);
    }
    assert(mailbox_try_pop(box, &out));
    assert(mailbox_overload(box) == 19);
    mailbox_delete(box);
}

static void
test_producers(size_t producer_count, size_t capacity) {
    const size_t total = producer_count * MESSAGES_PER_PRODUCER;
    mailbox_t *box = mailbox_new(capacity);
    pthread_t *threads = calloc(producer_count, sizeof(*threads));
    producer_args_t *args = calloc(producer_count, sizeof(*args));
    unsigned char *seen = calloc(total, 1);
    uint32_t *next = calloc(producer_count, sizeof(*next));
    size_t batch_count = 0;

    assert(box != NULL && threads != NULL && args != NULL && seen != NULL && next != NULL);
    for (size_t i = 0; i < producer_count; i++) {
        args[i] = (producer_args_t) { .box = box, .id = (uint32_t)i };
        assert(pthread_create(&threads[i], NULL, produce, &args[i]) == 0);
    }

    for (size_t received = 0; received < total;) {
        message_t message;
        if (!mailbox_try_pop(box, &message)) {
            sched_yield();
            continue;
        }

        size_t index = (size_t)message.from * MESSAGES_PER_PRODUCER + message.session;
        assert(index < total && seen[index] == 0);
        assert(message.session == next[message.from]++);
        seen[index] = 1;
        received++;
        batch_count++;
        if (batch_count == 256) {
            mailbox_finish_batch(box);
            batch_count = 0;
        }
        message_dispose(&message);
    }

    if (batch_count > 0)
        assert(!mailbox_finish_batch(box));

    for (size_t i = 0; i < producer_count; i++)
        assert(pthread_join(threads[i], NULL) == 0);
    for (size_t i = 0; i < total; i++)
        assert(seen[i] == 1);

    free(next);
    free(seen);
    free(args);
    free(threads);
    mailbox_delete(box);
}

int
main(void) {
    assert(mailbox_new(0) == NULL);
    test_schedule_and_close();
    test_non_power_of_two_capacity();
    test_batch_schedule();
    test_growth();
    test_overload();
    test_producers(1, 64);
    test_producers(2, 64);
    test_producers(4, 64);
    test_producers(16, 64);
    // Concurrent producers racing to grow a tiny mailbox.
    test_producers(16, 1);
    puts("mailbox_test: ok");
    return 0;
}
