#include "mailbox.h"

#include <stdbool.h>
#include <stdatomic.h>
#include <stdlib.h>

typedef struct spinlock {
    atomic_bool locked;
} spinlock_t;

struct mailbox {
    spinlock_t lock;
    message_t *items;
    size_t capacity;
    size_t head;
    size_t tail;
    size_t count;
    bool closed;
    bool scheduled;
};

static inline void
cpu_relax(void) {
#if defined(__i386__) || defined(__x86_64__)
    __builtin_ia32_pause();
#elif defined(__arm__) || defined(__aarch64__)
    __asm__ volatile("yield");
#endif
}

static inline void
spin_lock(spinlock_t *lock) {
    for (;;) {
        if (!atomic_exchange_explicit(
                &lock->locked, true, memory_order_acquire))
            return;
        while (atomic_load_explicit(&lock->locked, memory_order_relaxed))
            cpu_relax();
    }
}

static inline void
spin_unlock(spinlock_t *lock) {
    atomic_store_explicit(&lock->locked, false, memory_order_release);
}

mailbox_t *
mailbox_new(size_t capacity) {
    mailbox_t *box;

    if (capacity == 0)
        return NULL;

    box = calloc(1, sizeof(*box));
    if (box == NULL)
        return NULL;

    box->items = calloc(capacity, sizeof(*box->items));
    if (box->items == NULL) {
        free(box);
        return NULL;
    }

    atomic_init(&box->lock.locked, false);
    box->capacity = capacity;
    return box;
}

mailbox_result_t
mailbox_try_push(mailbox_t *box, const message_t *message, bool *notify) {
    mailbox_result_t result = MAILBOX_OK;

    *notify = false;
    spin_lock(&box->lock);
    if (box->closed) {
        result = MAILBOX_CLOSED;
    } else if (box->count == box->capacity) {
        result = MAILBOX_FULL;
    } else {
        box->items[box->tail] = *message;
        box->tail = (box->tail + 1) % box->capacity;
        box->count++;
        if (!box->scheduled) {
            box->scheduled = true;
            *notify = true;
        }
    }
    spin_unlock(&box->lock);
    return result;
}

bool
mailbox_try_pop(mailbox_t *box, message_t *out) {
    bool found = false;

    spin_lock(&box->lock);
    if (box->count > 0) {
        *out = box->items[box->head];
        box->head = (box->head + 1) % box->capacity;
        box->count--;
        found = true;
    } else {
        box->scheduled = false;
    }
    spin_unlock(&box->lock);
    return found;
}

void
mailbox_close(mailbox_t *box) {
    spin_lock(&box->lock);
    box->closed = true;
    spin_unlock(&box->lock);
}

void
mailbox_delete(mailbox_t *box) {
    message_t message;

    if (box == NULL)
        return;

    mailbox_close(box);
    while (mailbox_try_pop(box, &message))
        message_dispose(&message);

    free(box->items);
    free(box);
}
