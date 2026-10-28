#include "ctpc.h"

#include "log.h"
#include "msgq.h"

#include <stdlib.h>

#include "uv.h"

ctp_md_t * ctp_md_new() {
    ctp_md_t * md = (ctp_md_t *)calloc(1, sizeof(ctp_md_t));
    if (md == NULL)
        return NULL;
    md->mq = msgq_new();
    if (md->mq == NULL) {
        free(md);
        return NULL;
    }
    return md;
}

// Called on the SPI thread; takes ownership of msg. A tick is dropped when
// CTPC_MD_TICK_LIMIT ticks are already waiting, i.e. Lua is not keeping up.
void ctp_md_send(ctp_md_t * md, ctp_rsp_t * msg) {
    if (msgq_push(md->mq, msg, CTPC_MD_TICK_LIMIT) != 0) {
        ctp_rsp_free(msg);
        long long dropped = msgq_dropped(md->mq);
        if (dropped == 1 || dropped % 10000 == 0)
            log_warn("ctp_md_send | %d ticks queued, %lld dropped so far",
                CTPC_MD_TICK_LIMIT, dropped);
        return;
    }

    if (md->async) {
        uv_async_send(md->async);
    }
}

ctp_rsp_t * ctp_md_recv(ctp_md_t * md, bool blocking) {
    return msgq_pop(md->mq, blocking);
}

int ctp_md_drain(ctp_md_t * md) {
    int n = 0;
    ctp_rsp_t * r;
    while ((r = msgq_pop(md->mq, false)) != NULL) {
        ctp_rsp_free(r);
        n++;
    }
    return n;
}

long long ctp_md_ticks_dropped(ctp_md_t * md) {
    return msgq_dropped(md->mq);
}
