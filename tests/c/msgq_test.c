// msgq: FIFO order, ticks bounded and counted, events never refused, and
// ctp_md_send / ctp_md_drain on top of it. Built with ASan + UBSan, so a
// leaked or doubly freed message fails the run as well as a failed CHECK.
#include "ctpc.h"
#include "msgq.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define CHECK(cond, ...) do { \
        if (!(cond)) { \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__); \
            fputc('\n', stderr); \
            failures++; \
        } \
    } while (0)

static ctp_rsp_t *
msg(const char *name, uint32_t typ) {
    ctp_rsp_t *r = ctp_rsp_new(name, "", -1, true, NULL, 0, NULL, 0);
    r->rsp_typ = typ;
    return r;
}

static void
test_order_and_limit(void) {
    struct msgq *q = msgq_new();
    const size_t limit = 2;

    CHECK(msgq_push(q, msg("t1", CTPC_RSP_TICK), limit) == 0, "first tick");
    CHECK(msgq_push(q, msg("e1", CTPC_RSP_EVENT), limit) == 0, "event");
    CHECK(msgq_push(q, msg("t2", CTPC_RSP_TICK), limit) == 0, "second tick");

    ctp_rsp_t *t3 = msg("t3", CTPC_RSP_TICK);
    CHECK(msgq_push(q, t3, limit) == -1, "tick over the limit refused");
    ctp_rsp_free(t3); // refused: still ours
    CHECK(msgq_dropped(q) == 1, "dropped %lld", msgq_dropped(q));

    // events go in however many ticks are waiting
    CHECK(msgq_push(q, msg("e2", CTPC_RSP_EVENT), limit) == 0, "event at the tick limit");
    CHECK(msgq_length(q) == 4, "length %zu", msgq_length(q));

    const char *want[] = { "t1", "e1" };
    for (int i = 0; i < 2; i++) {
        ctp_rsp_t *r = msgq_pop(q, false);
        CHECK(r != NULL && strcmp(r->func_name, want[i]) == 0, "pop %d: %s", i, r ? r->func_name : "NULL");
        CHECK(r == NULL || r->_next == NULL, "popped message unlinked");
        ctp_rsp_free(r);
    }

    // one tick popped: room for one more
    CHECK(msgq_push(q, msg("t4", CTPC_RSP_TICK), limit) == 0, "tick after a pop");
    CHECK(msgq_dropped(q) == 1, "dropped unchanged");

    const char *rest[] = { "t2", "e2", "t4" };
    for (int i = 0; i < 3; i++) {
        ctp_rsp_t *r = msgq_pop(q, false);
        CHECK(r != NULL && strcmp(r->func_name, rest[i]) == 0, "pop rest %d: %s", i, r ? r->func_name : "NULL");
        ctp_rsp_free(r);
    }
    CHECK(msgq_pop(q, false) == NULL, "empty");
    CHECK(msgq_length(q) == 0, "length 0");

    // what is still queued is freed with the queue (LeakSanitizer checks)
    msgq_push(q, msg("left", CTPC_RSP_EVENT), limit);
    msgq_push(q, msg("left", CTPC_RSP_TICK), limit);
    msgq_delete(q);
}

static void
test_md_drain(void) {
    ctp_md_t *md = ctp_md_new();
    CHECK(md != NULL && md->state == CTPC_MD_DISCONNECTED, "new md");
    for (int i = 0; i < 5; i++)
        ctp_md_send(md, msg("OnRtnDepthMarketData", CTPC_RSP_TICK));
    ctp_md_send(md, msg("OnFrontDisconnected", CTPC_RSP_EVENT));

    ctp_rsp_t *r = ctp_md_recv(md, false);
    CHECK(r != NULL && r->rsp_typ == CTPC_RSP_TICK, "recv");
    ctp_rsp_free(r);
    CHECK(ctp_md_drain(md) == 5, "drain the rest");
    CHECK(ctp_md_recv(md, false) == NULL, "empty after drain");
    CHECK(ctp_md_ticks_dropped(md) == 0, "nothing dropped");
    msgq_delete(md->mq);
    free(md);
}

int
main(void) {
    test_order_and_limit();
    test_md_drain();
    if (failures > 0) {
        fprintf(stderr, "msgq_test: %d failures\n", failures);
        return 1;
    }
    printf("msgq_test: ok\n");
    return 0;
}
