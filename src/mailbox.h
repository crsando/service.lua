#ifndef SERVICE_MAILBOX_H
#define SERVICE_MAILBOX_H

#include <stdbool.h>
#include <stddef.h>

#include "message.h"

typedef struct mailbox mailbox_t;

/* MAILBOX_FULL only means the mailbox could not grow (out of memory). */
typedef enum mailbox_result {
    MAILBOX_OK = 0,
    MAILBOX_FULL,
    MAILBOX_CLOSED,
} mailbox_result_t;

/* capacity is the initial size; the mailbox doubles whenever it fills. */
mailbox_t *mailbox_new(size_t capacity);
/* On OK, the mailbox owns message->msg; notify tells the caller to wake it. */
mailbox_result_t mailbox_try_push(
    mailbox_t *box, const message_t *message, bool *notify);
/* An empty pop rearms notification for the next successful push. */
bool mailbox_try_pop(mailbox_t *box, message_t *out);
/* Completes a full consumer batch; true means the caller must wake again. */
bool mailbox_finish_batch(mailbox_t *box);
/* Returns and clears the queue length last seen past the overload threshold
 * (initially the initial capacity, doubling after each report), or 0. */
size_t mailbox_overload(mailbox_t *box);
size_t mailbox_capacity(mailbox_t *box);
void mailbox_close(mailbox_t *box);
/* No thread may enter the mailbox after mailbox_delete begins. */
void mailbox_delete(mailbox_t *box);

#endif
