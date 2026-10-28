#include "ctpc.h"

#include "log.h"
#include "cond.h"
#include "queue.h"

#include <string.h>
#include <assert.h>
#include <stdlib.h>

#include "uv.h"

#define _SERVICE_MQ_DEF_SIZE_ 1024

ctp_md_t * ctp_md_new() {
	ctp_md_t * md = (ctp_md_t *)malloc(sizeof(ctp_md_t));
	memset(md, 0, sizeof(ctp_md_t));

    md->q = queue_new_ptr(_SERVICE_MQ_DEF_SIZE_);
    md->c = (struct cond *)malloc(sizeof(struct cond));
    cond_create(md->c);
	return md;
}

void ctp_md_send(ctp_md_t * md, void *msg) {
	cond_trigger_begin(md->c);
    queue_push_ptr(md->q, msg);
    cond_trigger_end(md->c, 1);

    if(md->async) {
        uv_async_send(md->async);
    }
}

ctp_md_tick_t * ctp_md_recv(ctp_md_t * md, bool blocking) {
    ctp_md_tick_t * msg = NULL;
    cond_wait_begin(md->c);

    if(blocking) {
        if( queue_length(md->q) == 0 )
            cond_wait(md->c);
    }
    msg = (ctp_md_tick_t *)queue_pop_ptr(md->q);

    cond_wait_end(md->c);
    return msg;
}

void ctp_md_tick_free(ctp_md_tick_t * t) {
    // log_debug("ctp_md_tick_free");
    free(t);
}