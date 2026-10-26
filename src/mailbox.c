#include "mailbox.h"

#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
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
    size_t initial_capacity;
    // Overload report as in skynet: the threshold doubles past each report
    // and resets once the mailbox drains.
    size_t overload;
    size_t overload_threshold;
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
    box->initial_capacity = capacity;
    box->overload_threshold = capacity;
    return box;
}

// Moves the queued items into grown, which holds twice the capacity, and
// returns the old buffer for the caller to free outside the lock.
static message_t *
grow_locked(mailbox_t *box, message_t *grown) {
    message_t *old = box->items;

    for (size_t i = 0; i < box->count; i++)
        grown[i] = old[(box->head + i) % box->capacity];
    box->items = grown;
    box->head = 0;
    box->tail = box->count;
    box->capacity *= 2;
    return old;
}

mailbox_result_t
mailbox_try_push(mailbox_t *box, const message_t *message, bool *notify) {
    mailbox_result_t result = MAILBOX_OK;
    message_t *spare = NULL;
    message_t *garbage = NULL;

    *notify = false;
    spin_lock(&box->lock);
    while (!box->closed && box->count == box->capacity) {
        size_t capacity = box->capacity;

        if (spare != NULL) {
            garbage = grow_locked(box, spare);
            spare = NULL;
            break;
        }
        // Allocate outside the lock so other producers and the consumer
        // never spin on a malloc. Another producer may grow it meanwhile.
        spin_unlock(&box->lock);
        if (capacity <= SIZE_MAX / 2 / sizeof(*spare))
            spare = malloc(capacity * 2 * sizeof(*spare));
        if (spare == NULL)
            return MAILBOX_FULL;
        spin_lock(&box->lock);
        if (box->capacity != capacity) {
            free(spare);
            spare = NULL;
        }
    }
    if (box->closed) {
        result = MAILBOX_CLOSED;
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
    free(spare);
    free(garbage);
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
        while (box->count > box->overload_threshold) {
            box->overload = box->count;
            box->overload_threshold *= 2;
        }
    } else {
        box->scheduled = false;
        box->overload_threshold = box->initial_capacity;
    }
    spin_unlock(&box->lock);
    return found;
}

bool
mailbox_finish_batch(mailbox_t *box) {
    bool more;

    spin_lock(&box->lock);
    more = !box->closed && box->count > 0;
    if (!more)
        box->scheduled = false;
    spin_unlock(&box->lock);
    return more;
}

size_t
mailbox_overload(mailbox_t *box) {
    size_t overload;

    spin_lock(&box->lock);
    overload = box->overload;
    box->overload = 0;
    spin_unlock(&box->lock);
    return overload;
}

size_t
mailbox_capacity(mailbox_t *box) {
    size_t capacity;

    spin_lock(&box->lock);
    capacity = box->capacity;
    spin_unlock(&box->lock);
    return capacity;
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
