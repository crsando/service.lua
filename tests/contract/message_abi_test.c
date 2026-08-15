#include <stdint.h>

#include "message.h"

_Static_assert(sizeof(service_id_t) == sizeof(uint32_t),
    "service_id_t must be exactly 32 bits");
_Static_assert(sizeof(session_id_t) == sizeof(uint32_t),
    "session_id_t must be exactly 32 bits");

_Static_assert(MESSAGE_SYSTEM == 0, "MESSAGE_SYSTEM ABI changed");
_Static_assert(MESSAGE_REQUEST == 1, "MESSAGE_REQUEST ABI changed");
_Static_assert(MESSAGE_RESPONSE == 2, "MESSAGE_RESPONSE ABI changed");
_Static_assert(MESSAGE_ERROR == 3, "MESSAGE_ERROR ABI changed");
_Static_assert(MESSAGE_SIGNAL == 4, "MESSAGE_SIGNAL ABI changed");

_Static_assert(MESSAGE_RECEIPT_NONE == 0, "receipt ABI changed");
_Static_assert(MESSAGE_RECEIPT_DONE == 1, "receipt ABI changed");
_Static_assert(MESSAGE_RECEIPT_ERROR == 2, "receipt ABI changed");
_Static_assert(MESSAGE_RECEIPT_BLOCK == 3, "receipt ABI changed");
_Static_assert(MESSAGE_RECEIPT_RESPONCE == 4, "legacy receipt ABI changed");
_Static_assert(MESSAGE_RECEIPT_RESPONSE == MESSAGE_RECEIPT_RESPONCE,
    "receipt spelling aliases must have the same value");

int
main(void) {
    message_t message = {
        .from = UINT32_C(1),
        .to = UINT32_C(2),
        .session = UINT32_C(3),
        .type = MESSAGE_REQUEST,
        .msg = 0,
        .sz = 0,
    };

    return message.from == 1 &&
           message.to == 2 &&
           message.session == 3 &&
           message.type == MESSAGE_REQUEST ? 0 : 1;
}
