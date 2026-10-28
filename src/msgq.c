#include "msgq.h"

#include <pthread.h>
#include <stdlib.h>

struct msgq {
    pthread_mutex_t lock;
    pthread_cond_t nonempty;
    ctp_rsp_t * head;
    ctp_rsp_t * tail;
    size_t length;
    size_t ticks; // queued messages with rsp_typ CTPC_RSP_TICK
    long long dropped;
};

struct msgq *
msgq_new(void) {
    struct msgq * q = calloc(1, sizeof(*q));
    if (q == NULL)
        return NULL;
    pthread_mutex_init(&q->lock, NULL);
    pthread_cond_init(&q->nonempty, NULL);
    return q;
}

void
msgq_delete(struct msgq * q) {
    if (q == NULL)
        return;
    ctp_rsp_t * r;
    while ((r = msgq_pop(q, false)) != NULL)
        ctp_rsp_free(r);
    pthread_cond_destroy(&q->nonempty);
    pthread_mutex_destroy(&q->lock);
    free(q);
}

int
msgq_push(struct msgq * q, ctp_rsp_t * r, size_t tick_limit) {
    bool tick = r->rsp_typ == CTPC_RSP_TICK;

    pthread_mutex_lock(&q->lock);
    if (tick && q->ticks >= tick_limit) {
        q->dropped++;
        pthread_mutex_unlock(&q->lock);
        return -1;
    }
    r->_next = NULL;
    if (q->tail != NULL)
        q->tail->_next = r;
    else
        q->head = r;
    q->tail = r;
    q->length++;
    if (tick)
        q->ticks++;
    pthread_cond_signal(&q->nonempty);
    pthread_mutex_unlock(&q->lock);
    return 0;
}

ctp_rsp_t *
msgq_pop(struct msgq * q, bool blocking) {
    pthread_mutex_lock(&q->lock);
    while (blocking && q->head == NULL)
        pthread_cond_wait(&q->nonempty, &q->lock);
    ctp_rsp_t * r = q->head;
    if (r != NULL) {
        q->head = r->_next;
        if (q->head == NULL)
            q->tail = NULL;
        q->length--;
        if (r->rsp_typ == CTPC_RSP_TICK)
            q->ticks--;
        r->_next = NULL;
    }
    pthread_mutex_unlock(&q->lock);
    return r;
}

size_t
msgq_length(struct msgq * q) {
    pthread_mutex_lock(&q->lock);
    size_t n = q->length;
    pthread_mutex_unlock(&q->lock);
    return n;
}

long long
msgq_dropped(struct msgq * q) {
    pthread_mutex_lock(&q->lock);
    long long n = q->dropped;
    pthread_mutex_unlock(&q->lock);
    return n;
}
