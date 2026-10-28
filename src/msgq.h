#ifndef CTPC_MSGQ_H
#define CTPC_MSGQ_H

#include "ctpc.h"

/*
 * Message queue from a CTP callback thread to Lua: a FIFO of ctp_rsp_t,
 * linked through ctp_rsp_t._next, under one mutex. It has no fixed
 * capacity, so events (responses, state changes) are never lost; only
 * ticks are bounded, by the limit given to msgq_push.
 */
struct msgq;

struct msgq * msgq_new(void);
// Frees the queue and every message still in it.
void msgq_delete(struct msgq * q);

// Append r. A tick (rsp_typ CTPC_RSP_TICK) is refused when tick_limit ticks
// are already queued; the caller keeps it. Returns 0, or -1 if refused.
int msgq_push(struct msgq * q, ctp_rsp_t * r, size_t tick_limit);
// The oldest message, or NULL if none; with blocking, wait for one.
ctp_rsp_t * msgq_pop(struct msgq * q, bool blocking);

size_t msgq_length(struct msgq * q);
// Ticks refused so far.
long long msgq_dropped(struct msgq * q);

#endif
