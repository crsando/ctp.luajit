#ifndef _MACROS_H_
#define _MACROS_H_

// Body of every generated ctp_trader_ReqXxx (see tools/gen.lua): take the
// next request id and send. Requests come from the Lua thread and, while
// logging in, from the SPI thread, hence the atomic increment.
#define CTPC_TRADER_REQ(trader, cmd, field) \
    do { \
        if ((trader) == NULL || (field) == NULL) \
            return CTPC_E_INVALID; \
        CThostFtdcTraderApi * api_ = (CThostFtdcTraderApi *)((trader)->_api); \
        if (api_ == NULL) \
            return CTPC_E_NOT_STARTED; \
        int req_id_ = __atomic_add_fetch(&(trader)->req_id, 1, __ATOMIC_RELAXED); \
        int rc_ = api_->Req ## cmd(field, req_id_); \
        if (rc_ != 0) { \
            log_warn("Req%s | req_id: %d | failed: %d", #cmd, req_id_, rc_); \
            return rc_ < 0 ? rc_ : CTPC_E_UNKNOWN; \
        } \
        log_debug("Req%s | req_id: %d", #cmd, req_id_); \
        return req_id_; \
    } while (0)

#endif
