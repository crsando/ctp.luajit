#include "ctpc.h"
#include "cond.h"
#include "queue.h"
#include "log.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>

#include "uv.h"

#define _SERVICE_MQ_DEF_SIZE_ (1024)

ctp_trader_t * ctp_trader_new() {
    ctp_trader_t * t = (ctp_trader_t *)malloc(sizeof(ctp_trader_t));
    memset(t, 0, sizeof(ctp_trader_t));
    t->q = queue_new_ptr(_SERVICE_MQ_DEF_SIZE_);
    t->c = (struct cond *)malloc(sizeof(struct cond));
    cond_create(t->c);
    return t;
}

void ctp_trader_send(ctp_trader_t * t, ctp_rsp_t * msg) {
	cond_trigger_begin(t->c);
    queue_push_ptr(t->q, msg);
    cond_trigger_end(t->c, 1);

    if(t->async) {
        uv_async_send(t->async);
    }
}

ctp_rsp_t * ctp_trader_recv(ctp_trader_t * t, bool blocking) {
    ctp_rsp_t * msg = NULL;
    cond_wait_begin(t->c);

    if(blocking) {
        if ( queue_length(t->q) == 0 )
            cond_wait(t->c);
    }
    msg = (ctp_rsp_t *)queue_pop_ptr(t->q);

    cond_wait_end(t->c);
    return msg;
}

void ctp_trader_release(ctp_trader_t * t) {
    queue_delete(t->q);
    cond_release(t->c);
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

void ctp_trader_wait_for_settle(ctp_trader_t * t) {
    while(t->connected != 4) {
        ctp_rsp_t * rsp = ctp_trader_recv(t, true);
        ctp_rsp_free(rsp);
    }
}