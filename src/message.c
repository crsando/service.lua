#include "message.h"
#include <stdlib.h>

void
message_dispose(message_t *message) {
    if (message == NULL)
        return;

    free(message->msg);
    message->msg = NULL;
    message->sz = 0;
}
