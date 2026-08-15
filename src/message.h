#ifndef ltask_message_h
#define ltask_message_h

#include <stddef.h>
#include <stdint.h>

typedef uint32_t service_id_t;
typedef uint32_t session_id_t;

/* Compatibility aliases used by the copied implementation. */
typedef service_id_t service_id;
typedef session_id_t session_t;

typedef enum message_type {
    MESSAGE_SYSTEM = 0,
    MESSAGE_REQUEST = 1,
    MESSAGE_RESPONSE = 2,
    MESSAGE_ERROR = 3,
    MESSAGE_SIGNAL = 4,
} message_type_t;

typedef enum message_receipt {
    MESSAGE_RECEIPT_NONE = 0,
    MESSAGE_RECEIPT_DONE = 1,
    MESSAGE_RECEIPT_ERROR = 2,
    MESSAGE_RECEIPT_BLOCK = 3,
    MESSAGE_RECEIPT_RESPONCE = 4,
    MESSAGE_RECEIPT_RESPONSE = 4,
} message_receipt_t;

// If to == 0, it's a schedule message. It should be post from root service (1).
// type is MESSAGE_SCHEDULE_* from is the parameter (for DEL service_id).
#define MESSAGE_SCHEDULE_NEW 0
#define MESSAGE_SCHEDULE_DEL 1

struct message {
    service_id_t from;
    service_id_t to;
    session_id_t session;
    int type;
    void *msg;
    size_t sz;
};

typedef struct message message_t;

void message_dispose(message_t *message);

#endif
