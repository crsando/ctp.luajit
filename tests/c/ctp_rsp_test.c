// ctp_rsp_new / ctp_rsp_free / ctp_trader_drain. Built with ASan + UBSan, so
// an overflow or a leaked block fails the run as well as a failed CHECK.
#include "ctpc.h"
#include "msgq.h"

#include <stdint.h>
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

static int
aligned(const void *p) {
    return (uintptr_t)p % _Alignof(max_align_t) == 0;
}

static int
inside(const ctp_rsp_t *r, const void *p, size_t n) {
    // The block is at least header + payloads long; p must lie past the header.
    return (const char *)p >= (const char *)(r + 1) && n > 0;
}

static void
test_full(void) {
    char field[37], info[85];
    for (size_t i = 0; i < sizeof(field); i++) field[i] = (char)(i + 1);
    for (size_t i = 0; i < sizeof(info); i++) info[i] = (char)(200 - i);

    ctp_rsp_t *r = ctp_rsp_new("OnRspQryOrder", "CThostFtdcOrderField", 7, true,
        field, sizeof(field), info, sizeof(info));
    CHECK(r != NULL, "allocation failed");
    if (r == NULL)
        return;
    CHECK(strcmp(r->func_name, "OnRspQryOrder") == 0, "func_name: %s", r->func_name);
    CHECK(strcmp(r->field_name, "CThostFtdcOrderField") == 0, "field_name: %s", r->field_name);
    CHECK(strcmp(r->desc, "CThostFtdcOrderField") == 0, "desc: %s", r->desc);
    CHECK(r->req_id == 7 && r->is_last && r->last == 1, "header fields");
    CHECK(r->size == sizeof(field), "size: %zu", r->size);
    CHECK(inside(r, r->field, r->size) && aligned(r->field), "field placement");
    CHECK(memcmp(r->field, field, sizeof(field)) == 0, "field content");
    CHECK((char *)r->rsp_info >= (char *)r->field + sizeof(field) && aligned(r->rsp_info),
        "rsp_info placement");
    CHECK(memcmp(r->rsp_info, info, sizeof(info)) == 0, "rsp_info content");
    ctp_rsp_free(r);
}

static void
test_empty(void) {
    // A size without data, as OnRspError and OnFrontDisconnected send.
    ctp_rsp_t *r = ctp_rsp_new("OnFrontDisconnected", "", -1, false, NULL, 99, NULL, 85);
    CHECK(r != NULL, "allocation failed");
    if (r == NULL)
        return;
    CHECK(r->field == NULL && r->size == 0, "field should be empty");
    CHECK(r->rsp_info == NULL, "rsp_info should be empty");
    CHECK(r->req_id == -1 && !r->is_last && r->last == 0, "header fields");
    CHECK(strcmp(r->field_name, "") == 0 && strcmp(r->desc, "") == 0, "names");
    ctp_rsp_free(r);

    r = ctp_rsp_new(NULL, NULL, 0, true, NULL, 0, "x", 1);
    CHECK(r != NULL && r->func_name[0] == '\0' && r->field_name[0] == '\0', "NULL names");
    CHECK(r != NULL && r->rsp_info != NULL && *(char *)r->rsp_info == 'x', "info only");
    ctp_rsp_free(r);
    ctp_rsp_free(NULL);
}

static void
test_long_name(void) {
    char name[600];
    memset(name, 'n', sizeof(name) - 1);
    name[sizeof(name) - 1] = '\0';
    ctp_rsp_t *r = ctp_rsp_new(name, name, 1, true, NULL, 0, NULL, 0);
    CHECK(r != NULL, "allocation failed");
    if (r == NULL)
        return;
    CHECK(strlen(r->func_name) == sizeof(r->func_name) - 1, "func_name not truncated");
    CHECK(strlen(r->field_name) == sizeof(r->field_name) - 1, "field_name not truncated");
    ctp_rsp_free(r);
}

static void
test_drain(void) {
    ctp_trader_t *t = ctp_trader_new();
    char field[16] = "payload";
    for (int i = 0; i < 5; i++)
        ctp_trader_send(t, ctp_rsp_new("OnRtnOrder", "F", i, true, field, sizeof(field), NULL, 0));
    CHECK(ctp_trader_drain(t) == 5, "drain count");
    CHECK(ctp_trader_recv(t, false) == NULL, "queue not empty after drain");
    CHECK(ctp_trader_drain(t) == 0, "second drain");

    msgq_delete(t->mq);
    free(t);
}

int
main(void) {
    test_full();
    test_empty();
    test_long_name();
    test_drain();
    if (failures == 0)
        printf("ctp_rsp_test: ok\n");
    return failures ? 1 : 0;
}
