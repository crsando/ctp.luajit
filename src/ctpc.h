#ifndef CTPC_H
#define CTPC_H

#include "ThostFtdcUserApiDataType.h"
#include "ThostFtdcUserApiStruct.h"
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// A message from a CTP callback thread to Lua: one callback's arguments,
// copied into one allocation. Lifecycle and ownership: docs/ctp_rsp.md.
enum {
    CTPC_RSP_EVENT = 0, // responses and state changes: never dropped
    CTPC_RSP_TICK = 1,  // market data: dropped when too many are queued
};

typedef struct {
    // header
    uint32_t rsp_typ; // CTPC_RSP_*
    char desc[256];
    char func_name[256];
    char field_name[256];

    // main body
    int req_id;
    void * field;
    size_t size;
    int last;
    bool is_last;

    // common
    void * rsp_info;

    void * _next; // link in the market data queue (src/msgq.c)
} ctp_rsp_t;

// Market data connection state, ctp_md_t.state. Written by the SPI thread;
// every change is also queued as a message (see ctp_md_recv).
enum {
    CTPC_MD_DISCONNECTED = 0, // not started, or connection lost (CTP reconnects)
    CTPC_MD_CONNECTED = 1,    // connected, logging in
    CTPC_MD_LOGGED_IN = 2,    // ready for subscriptions
};

typedef struct {
    // tcp://xxx.xxx.xxx.xxx:xxxx
    char front_addr[128]; // FrontAddr
    char broker[11]; // BrokerID
    char user[13]; // InvestorID

    int state; // CTPC_MD_*

    void * _spi;
    void * _api;

    struct msgq * mq; // messages for Lua: events and ticks, in arrival order

    void * async; // libuv async handler
} ctp_md_t;

// At most this many ticks wait in the queue; newer ticks are dropped and
// counted. Events are always queued.
#define CTPC_MD_TICK_LIMIT 100000

// Applicaton Interface
ctp_md_t * ctp_md_new();
ctp_md_t * ctp_md_init(ctp_md_t * md, const char front_addr[], const char broker[], const char user[]);

// 0 when sent; CTP's error code, or CTPC_E_NOT_STARTED before ctp_md_start.
int ctp_md_subscribe(ctp_md_t * md, char * symbols[], int num);
int ctp_md_unsubscribe(ctp_md_t * md, char * symbols[], int num);

// 1 when the API is created and connecting, 0 on failure (logged) or when
// already started. The outcome of connecting and logging in arrives as
// OnFrontConnected / OnRspUserLogin messages.
int ctp_md_start(ctp_md_t * md);
// Release the API and free every queued message.
int ctp_md_stop(ctp_md_t * md);

// Messages, in arrival order:
//   OnFrontConnected      no field
//   OnRspUserLogin        CThostFtdcRspUserLoginField; rsp_info.ErrorID != 0 on
//                         failure, negative when ReqUserLogin could not be sent
//   OnFrontDisconnected   rsp_info.ErrorID is CTP's reason code
//   OnRspSubMarketData / OnRspUnSubMarketData / OnRspError
//   OnRtnDepthMarketData  CThostFtdcDepthMarketDataField, rsp_typ CTPC_RSP_TICK
void ctp_md_send(ctp_md_t * md, ctp_rsp_t * msg);
ctp_rsp_t * ctp_md_recv(ctp_md_t * md, bool blocking);
// Free every message still queued; returns how many were freed.
int ctp_md_drain(ctp_md_t * md);
// Ticks dropped because CTPC_MD_TICK_LIMIT were already queued.
long long ctp_md_ticks_dropped(ctp_md_t * md);


// Trading connection state, ctp_trader_t.state. Written by the SPI thread,
// which runs the login chain on every (re)connect: authenticate, log in,
// confirm the settlement. Every step is also queued as a message.
enum {
    CTPC_TRADER_DISCONNECTED = 0,  // not started, or connection lost (CTP reconnects)
    CTPC_TRADER_CONNECTED = 1,     // connected, authenticating
    CTPC_TRADER_AUTHENTICATED = 2, // logging in
    CTPC_TRADER_LOGGED_IN = 3,     // confirming the settlement
    CTPC_TRADER_READY = 4,         // settlement confirmed: ready for requests
};

// declarations
struct _ctp_trader_t;
typedef struct _ctp_trader_t ctp_trader_t;

typedef struct _ctp_trader_t {
    char front_addr[128]; // FrontAddr
    char broker[11]; // BrokerID
    char user[13]; // InvestorID
    char password[41]; // InvestorPassword
    char app_id[256];
    char auth_code[256];

    int state; // CTPC_TRADER_*

    // session info, from OnRspUserLogin
    int front_id;
    int	session_id;	//会话编号
    char max_order_ref[13];	//报单引用
    char lst_order_ref[13];

    // class pointer
    void * _spi;
    void * _api;

    int req_id; // last request id; incremented atomically by every ctp_trader_ReqXxx

    struct msgq * mq; // messages for Lua, in arrival order; never dropped

    void * async; // libuv async handler
} ctp_trader_t;

ctp_trader_t * ctp_trader_new();
ctp_trader_t * ctp_trader_init(ctp_trader_t * trader, const char front_addr[], const char broker[], 
    const char user[], const char password[], const char app_id[], const char auth_code[]);

// 1 when the API is created and connecting, 0 on failure (logged) or when
// already started. The outcome arrives as messages:
//   OnFrontConnected            no field
//   OnRspAuthenticate           CThostFtdcRspAuthenticateField
//   OnRspUserLogin              CThostFtdcRspUserLoginField (FrontID, SessionID, ...)
//   OnRspSettlementInfoConfirm  CThostFtdcSettlementInfoConfirmField; success means READY
//   OnFrontDisconnected         rsp_info.ErrorID is CTP's reason code
// A failed step has rsp_info.ErrorID != 0, negative when its request could
// not be sent; the chain then stops until the next reconnect.
int ctp_trader_start(ctp_trader_t * trader);
// Release the API and free every queued message.
int ctp_trader_stop(ctp_trader_t * trader);

// Build a message in one allocation: field and rsp_info are copied right after
// the header, so ctp_rsp_free releases all of it. field / rsp_info may be NULL.
// Returns NULL when out of memory.
ctp_rsp_t * ctp_rsp_new(const char * func_name, const char * field_name, int req_id, bool is_last,
    const void * field, size_t size, const void * rsp_info, size_t rsp_info_size);
void ctp_trader_send(ctp_trader_t * t, ctp_rsp_t * msg);
ctp_rsp_t * ctp_trader_recv(ctp_trader_t * t, bool blocking);
void ctp_rsp_free(ctp_rsp_t * r);
// Free every message still queued; returns how many were freed.
int ctp_trader_drain(ctp_trader_t * t);

// Request wrappers: ctp_trader_ReqXxx for every CThostFtdcTraderApi::ReqXxx,
// generated by tools/gen.lua into ctpc_req.h. Return values:
enum {
    // > 0: the request id, matched by the OnRspXxx responses
    CTPC_E_NETWORK = -1,        // CTP: network failure
    CTPC_E_PENDING = -2,        // CTP: too many requests waiting for a response
    CTPC_E_RATE = -3,           // CTP: too many requests in this second
    CTPC_E_NOT_STARTED = -100,  // no API: ctp_trader_start has not run, or stopped
    CTPC_E_INVALID = -101,      // NULL trader or field
    CTPC_E_UNKNOWN = -102,      // CTP returned an undocumented code
};

// Order insertion keeps its hand-written wrapper until order refs move to
// Lua; returns like ctp_trader_ReqOrderInsert.
int ctp_trader_order_insert(ctp_trader_t * t, const char * symbol, double price, int volume, char flag);

// "<ctp version> cdef=<hash>"; the generated cdefs.lua must carry the same.
const char * ctpc_build_info(void);

#include "ctpc_req.h"

#endif
