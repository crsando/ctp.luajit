#include "ctpc.h"
#include "msgq.h"
#include "log.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>

#include "uv.h"

ctp_trader_t * ctp_trader_new() {
    ctp_trader_t * t = (ctp_trader_t *)calloc(1, sizeof(ctp_trader_t));
    if (t == NULL)
        return NULL;
    t->mq = msgq_new();
    if (t->mq == NULL) {
        free(t);
        return NULL;
    }
    return t;
}

// Called on the SPI thread; takes ownership of msg. Trading messages are
// never dropped: the queue has no limit for them.
void ctp_trader_send(ctp_trader_t * t, ctp_rsp_t * msg) {
    msg->rsp_typ = CTPC_RSP_EVENT;
    msgq_push(t->mq, msg, 0);

    if(t->async) {
        uv_async_send(t->async);
    }
}

ctp_rsp_t * ctp_trader_recv(ctp_trader_t * t, bool blocking) {
    return msgq_pop(t->mq, blocking);
}

// field and rsp_info start on the same alignment malloc gives the header.
static size_t rsp_align(size_t n) {
    size_t a = _Alignof(max_align_t);
    return (n + a - 1) & ~(a - 1);
}

ctp_rsp_t * ctp_rsp_new(const char * func_name, const char * field_name, int req_id, bool is_last,
    const void * field, size_t size, const void * rsp_info, size_t rsp_info_size) {
    size_t field_len = field ? size : 0;
    size_t info_len = rsp_info ? rsp_info_size : 0;
    size_t field_off = rsp_align(sizeof(ctp_rsp_t));
    size_t info_off = field_off + rsp_align(field_len);

    ctp_rsp_t * r = (ctp_rsp_t *)calloc(1, info_off + info_len);
    if (r == NULL)
        return NULL;

    snprintf(r->desc, sizeof(r->desc), "%s", field_name ? field_name : "");
    snprintf(r->func_name, sizeof(r->func_name), "%s", func_name ? func_name : "");
    snprintf(r->field_name, sizeof(r->field_name), "%s", field_name ? field_name : "");
    r->req_id = req_id;
    r->last = is_last ? 1 : 0;
    r->is_last = is_last;
    if (field_len > 0) {
        r->field = (char *)r + field_off;
        memcpy(r->field, field, field_len);
        r->size = field_len;
    }
    if (info_len > 0) {
        r->rsp_info = (char *)r + info_off;
        memcpy(r->rsp_info, rsp_info, info_len);
    }
    return r;
}

// field and rsp_info live in the same block (see ctp_rsp_new).
void ctp_rsp_free(ctp_rsp_t * r) {
    free(r);
}

int ctp_trader_drain(ctp_trader_t * t) {
    int n = 0;
    ctp_rsp_t * r;
    while ((r = ctp_trader_recv(t, false)) != NULL) {
        ctp_rsp_free(r);
        n++;
    }
    return n;
}
