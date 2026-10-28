#include <iostream>
#include <stdio.h>
#include <string>

#include "malloc.h"
#include "string.h"
#include "stdlib.h"

#include "CustomMdSpi.h"
#include "CustomTradeSpi.h"

#include "assert.h"

#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>

extern "C" {
#include "log.h"
#include "ctp_stdio.h"
#include "ctpc.h"

// CTP flow files (*.con) go to /dev/shm/<root>/<broker>/<user>/
#define _FLOW_BASE_ "/dev/shm"

// mkdir one level, then make sure it is a real directory owned by us
static int ctp_flow_mkdir(const char * path) {
    struct stat st;
    if (mkdir(path, 0700) != 0 && errno != EEXIST) {
        log_error("flow path | mkdir %s | %s", path, strerror(errno));
        return -1;
    }
    if (lstat(path, &st) != 0) {
        log_error("flow path | lstat %s | %s", path, strerror(errno));
        return -1;
    }
    if (!S_ISDIR(st.st_mode) || st.st_uid != getuid()) {
        log_error("flow path | %s is not a directory owned by uid %d", path, (int)getuid());
        return -1;
    }
    return 0;
}

// build /dev/shm/<root>/<broker>/<user>/ (with trailing '/') and create it
static int ctp_flow_path(char * out, size_t n, const char * root, const char * broker, const char * user) {
    const char * parts[3] = { root, broker, user };
    size_t len = (size_t)snprintf(out, n, "%s", _FLOW_BASE_);

    for (int i = 0; i < 3; i++) {
        const char * p = (parts[i] && parts[i][0]) ? parts[i] : "_";
        if (strchr(p, '/') || strcmp(p, ".") == 0 || strcmp(p, "..") == 0) {
            log_error("flow path | invalid component: %s", p);
            return -1;
        }
        int r = snprintf(out + len, n - len, "/%s", p);
        if (r < 0 || (size_t)r >= n - len) {
            out[len] = '\0';
            log_error("flow path | too long: %s/%s", out, p);
            return -1;
        }
        len += (size_t)r;
        if (ctp_flow_mkdir(out) != 0)
            return -1;
    }

    if (len + 1 >= n) {
        log_error("flow path | too long: %s/", out);
        return -1;
    }
    out[len] = '/';
    out[len + 1] = '\0';
    return 0;
}

// MD API
#define _api(md) ((CThostFtdcMdApi *)((md)->_api))
#define _spi(md) ((CustomMdSpi *)((md)->_spi))

int ctp_md_start(ctp_md_t * md) {
    if( (md->_api != NULL) || (md->_spi != NULL) ) { 
        log_debug("api/spi already initialized, abort ctp_md_start");
        return 0;
    }

    char flow[256];
    if (ctp_flow_path(flow, sizeof(flow), "ctp_md", md->broker, md->user) != 0) {
        log_error("ctp_md_start | flow path not ready, abort");
        return 0;
    }

    log_debug("ctp_md_start | init Spi/Api | flow path %s", flow);

	CustomMdSpi * pMdUserSpi = new CustomMdSpi();       // 创建行情回调实例

    // 我们需要保存这个member变量，这个变量在Login的过程中有用到
	ctp_stdio_init();
	pMdUserSpi->g_pMdUserApi = CThostFtdcMdApi::CreateFtdcMdApi(flow);   // 创建行情实例
	pMdUserSpi->g_pMdUserApi->RegisterSpi(pMdUserSpi);               // 注册事件类
	pMdUserSpi->g_pMdUserApi->RegisterFront(md->front_addr);           // 设置行情前置地址
	
	md->_spi = (void *)pMdUserSpi;
	md->_api = (void *)(pMdUserSpi->g_pMdUserApi);

	_spi(md)->_md = md;
	_api(md)->Init();

    return 1;
}

int ctp_md_stop(ctp_md_t * md) {
    log_debug("ctp_md_stop");
    // Release API First
    if( _api(md) ) {
        _api(md)->RegisterSpi(NULL);
        _api(md)->Release();
        md->_api = NULL;
    }
    if( _spi(md) ) {
        // Delete Spi
        delete _spi(md);
        md->_spi = NULL;
    }

    // Update Connected Status
    md->connected = 0;

    return 1;
}


ctp_md_t * ctp_md_init(ctp_md_t * md, const char front_addr[], const char broker[], const char user[]) 
{
    log_debug("ctp_md_init | api version | %s", CThostFtdcMdApi::GetApiVersion());
    log_debug("ctp_md_init | %s | %s", front_addr, broker);

	// <TODO> Check string length
	strcpy(md->front_addr, &front_addr[0]);
	strcpy(md->broker, &broker[0]);
	strcpy(md->user, &user[0]);

    md->_api = NULL;
    md->_spi = NULL;

	md->connected = 0;

	return md;
}

int ctp_md_subscribe(ctp_md_t * md, char * symbols [], int num) {
    return _api(md)->SubscribeMarketData(symbols, num);
}
int ctp_md_unsubscribe(ctp_md_t * md, char * symbols [], int num) {
    return _api(md)->UnSubscribeMarketData(symbols, num);
}

// Trader API
#undef _spi
#undef _api
#define _spi(t) ((CustomTradeSpi *)((t)->_spi))
#define _api(t) ((CThostFtdcTraderApi *)((t)->_api))

ctp_trader_t * ctp_trader_init(
    ctp_trader_t * trader, 
    const char front_addr[], const char broker[], 
    const char user[], const char password[],
    const char app_id[], const char auth_code[]
    )
{
    log_debug("ctp_trader_init | api version | %s", CThostFtdcTraderApi::GetApiVersion());
	log_debug("ctp_trader_init | %s | %s | %s | %s", front_addr, broker, user, app_id);
    if(trader == NULL) {
        trader = ctp_trader_new();
    }
	assert(trader != NULL);

    strcpy(trader->front_addr, front_addr);
    strcpy(trader->broker, broker);
    strcpy(trader->user, user);
    strcpy(trader->password, password);
    strcpy(trader->app_id, app_id);
    strcpy(trader->auth_code, auth_code);

	return trader;
}

int ctp_trader_start(ctp_trader_t * trader) {
    if((trader->_spi != NULL) || (trader->_api !=NULL)) {
        log_debug("ctp_trader_start: already initialized");
        return 0;
    }

    trader->connected = 0;

    char flow[256];
    if (ctp_flow_path(flow, sizeof(flow), "ctp_trader", trader->broker, trader->user) != 0) {
        log_error("ctp_trader_start | flow path not ready, abort");
        return 0;
    }
    log_debug("ctp_trader_start | flow path %s", flow);

    ctp_stdio_init();
    CThostFtdcTraderApi * pTradeUserApi = CThostFtdcTraderApi::CreateFtdcTraderApi(flow); // 创建交易实例
	CustomTradeSpi *pTradeSpi = new CustomTradeSpi;               // 创建交易回调实例

    pTradeSpi->_trader = trader;
    trader->_spi = (void *)pTradeSpi;
    trader->_api = (void *)pTradeUserApi;
	pTradeUserApi->RegisterSpi(pTradeSpi);                      // 注册事件类
	pTradeUserApi->SubscribePublicTopic(THOST_TERT_RESTART);    // 订阅公共流
	pTradeUserApi->SubscribePrivateTopic(THOST_TERT_RESTART);   // 订阅私有流
	pTradeUserApi->RegisterFront(trader->front_addr);              // 设置交易前置地址

	_api(trader)->Init();
    return 1;
}

int ctp_trader_stop(ctp_trader_t * trader) {
    log_debug("ctp_trader_stop");
    if(trader->_api) {
        _api(trader)->RegisterSpi(NULL);
        _api(trader)->Release();
        trader->_api = NULL;
    }
    if(trader->_spi) {
        delete _spi(trader);
        trader->_spi = NULL;
    }
    // Release() has returned, so no callback can queue anything more; what is
    // left belongs to the session that just ended.
    int dropped = ctp_trader_drain(trader);
    if (dropped > 0)
        log_debug("ctp_trader_stop | dropped %d pending messages", dropped);

    trader->connected = 0;

    return 1;
}

int ctp_trader_order_insert(ctp_trader_t * t, const char * symbol, double price, int volume, char flag)
{
    log_debug("ctp_trader_order_insert %s | %lf | %d | %d", symbol, price, volume, flag);
    int order_ref_i = 0;
	CThostFtdcInputOrderField orderInsertReq;
	memset(&orderInsertReq, 0, sizeof(orderInsertReq));
	strcpy(orderInsertReq.BrokerID, t->broker);
	strcpy(orderInsertReq.InvestorID, t->user);
	strcpy(orderInsertReq.InstrumentID, symbol);

    order_ref_i = atoi(t->lst_order_ref) + 1;
    sprintf(orderInsertReq.OrderRef, "%012d", order_ref_i);
    sprintf(t->lst_order_ref, "%012d", order_ref_i);
    log_debug("order_ref: %s | %s", orderInsertReq.OrderRef, t->lst_order_ref);

    if ( price < 0.0001 ) {
        log_debug("ctp_trader_order_insert | market order");
        // orderInsertReq.OrderPriceType = THOST_FTDC_OPT_AnyPrice;
        orderInsertReq.OrderPriceType = THOST_FTDC_OPT_LastPrice;
        // orderInsertReq.LimitPrice = 0.0;
        orderInsertReq.TimeCondition = THOST_FTDC_TC_IOC; // 立即成交否则撤销
    }
    else {
        // limit order
        log_debug("ctp_trader_order_insert | limit order | %lf", price);
        orderInsertReq.OrderPriceType = THOST_FTDC_OPT_LimitPrice;
        orderInsertReq.LimitPrice = price;
        orderInsertReq.TimeCondition = THOST_FTDC_TC_GFD; // 当日有效
    }

    orderInsertReq.CombOffsetFlag[0] = flag;
	orderInsertReq.CombHedgeFlag[0] = THOST_FTDC_HF_Speculation;

	orderInsertReq.Direction = (volume > 0 ? THOST_FTDC_D_Buy : THOST_FTDC_D_Sell);
	orderInsertReq.VolumeTotalOriginal = abs(volume); // input volume
	orderInsertReq.VolumeCondition = THOST_FTDC_VC_AV;
	orderInsertReq.MinVolume = 1;

	orderInsertReq.ContingentCondition = THOST_FTDC_CC_Immediately;
	orderInsertReq.ForceCloseReason = THOST_FTDC_FCC_NotForceClose;
	orderInsertReq.IsAutoSuspend = 0;
	orderInsertReq.UserForceClose = 0;

    log_debug("OrderPriceType=%c", orderInsertReq.OrderPriceType);
    log_debug("Direction=%c", orderInsertReq.Direction);
    log_debug("CombOffsetFlag[0]=%c", orderInsertReq.CombOffsetFlag[0]);
    return ctp_trader_ReqOrderInsert(t, &orderInsertReq);
}

} // end extern "C"