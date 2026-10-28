#include <iostream>
#include <time.h>
#include <thread>
#include <chrono>
#include "string.h"
#include "malloc.h"
#include "CustomTradeSpi.h"

extern "C" {
	#include "log.h"
}

// Copy a callback's arguments into one message and queue it for Lua.
static void send_rsp(ctp_trader_t * t, const char * fn, const char * field_name,
	int req_id, bool is_last, const void * field, size_t size, CThostFtdcRspInfoField * info)
{
	ctp_rsp_t * rsp = ctp_rsp_new(fn, field_name, req_id, is_last, field, size,
		info, sizeof(CThostFtdcRspInfoField));
	if (rsp == NULL) {
		log_error("%s | out of memory, response dropped", fn);
		return;
	}
	ctp_trader_send(t, rsp);
}

void CustomTradeSpi::OnFrontConnected()
{
	log_debug("OnFrontConnected | FrontAddr:%s", this->_trader->front_addr);
	this->_trader->connected = 1;
	this->reqAuthenticate();
}

int CustomTradeSpi::reqAuthenticate() {
	CThostFtdcReqAuthenticateField field;
	memset(&field, 0, sizeof(field));
	strcpy(field.BrokerID, this->_trader->broker);
	strcpy(field.UserID, this->_trader->user);
	strcpy(field.AppID, this->_trader->app_id);
	strcpy(field.AuthCode, this->_trader->auth_code);
	return ctp_trader_ReqAuthenticate(this->_trader, &field);
}

void CustomTradeSpi::OnRspAuthenticate(CThostFtdcRspAuthenticateField *pRspAuthenticateField, CThostFtdcRspInfoField *pRspInfo, int nRequestID, bool bIsLast)
{
	if (!isErrorRspInfo(pRspInfo)) {
		log_debug("OnRspAuthenticate | Success | AppID:%s", this->_trader->app_id);
		this->_trader->connected = 2;
		reqUserLogin();
	}
	else
		log_error("OnRspAuthenticate | Fail | AppID:%s | %d | %s", this->_trader->app_id, pRspInfo->ErrorID, pRspInfo->ErrorMsg);
}

void CustomTradeSpi::OnRspUserLogin(
	CThostFtdcRspUserLoginField *pRspUserLogin,
	CThostFtdcRspInfoField *pRspInfo,
	int nRequestID,
	bool bIsLast)
{
	if (!isErrorRspInfo(pRspInfo))
	{
		this->_trader->connected = 3;
		log_debug("OnRspUserLogin | Success | BrokerID:%s | UserID:%s", pRspUserLogin->BrokerID, pRspUserLogin->UserID);
		log_debug("OnRspUserLogin | FrontID: %d | SessionID: %d | MaxOrderRef: %s",
			pRspUserLogin->FrontID, pRspUserLogin->SessionID, pRspUserLogin->MaxOrderRef);


		// session info
		this->_trader->front_id = pRspUserLogin->FrontID;
		this->_trader->session_id = pRspUserLogin->SessionID;
		strcpy(this->_trader->max_order_ref, pRspUserLogin->MaxOrderRef);
		strcpy(this->_trader->lst_order_ref, pRspUserLogin->MaxOrderRef);

		// 投资者结算结果确认
		reqSettlementInfoConfirm();
	}
	else
		log_error("OnRspUserLogin | Fail | BrokerID:%s | UserID:%s | %d | %s", this->_trader->broker, this->_trader->user, pRspInfo->ErrorID, pRspInfo->ErrorMsg);
}

void CustomTradeSpi::OnRspError(CThostFtdcRspInfoField *pRspInfo, int nRequestID, bool bIsLast)
{
	if (pRspInfo)
		log_error("OnRspError | %d | %s", pRspInfo->ErrorID, pRspInfo->ErrorMsg);
	send_rsp(this->_trader, "OnRspError", "", nRequestID, bIsLast, NULL, 0, pRspInfo);
}

void CustomTradeSpi::OnFrontDisconnected(int nReason)
{
	log_warn("OnFrontDisconnected | FrontAddr:%s | nReason:%d", this->_trader->front_addr, nReason);
	this->_trader->connected = 0;
	send_rsp(this->_trader, "OnFrontDisconnected", "", -1, true, NULL, 0, NULL);
}

void CustomTradeSpi::OnHeartBeatWarning(int nTimeLapse)
{
	log_warn("OnHeartBeatWarning | nTimeLapse: %d", nTimeLapse);
}



#define ON_RSP_THEN_SEND(fn ,tp) \
	send_rsp(this->_trader, #fn, #tp, nRequestID, bIsLast, pField, sizeof(tp), pRspInfo)

// this macro is used for Order/Trade Response
#define ON_RSP_THEN_SEND_COMPACT(fn, tp) \
    do { \
        CThostFtdcRspInfoField *pRspInfo = NULL; \
        bool bIsLast = true; \
        int nRequestID = -1; \
        ON_RSP_THEN_SEND(fn, tp); \
    } while(0)


#define CUSTOM_ON(fn, tp) \
void CustomTradeSpi::fn (tp * pField, CThostFtdcRspInfoField * pRspInfo, int nRequestID, bool bIsLast)  { \
    log_debug("%s | nRequestID : %d | isLast: %d", #fn, nRequestID, bIsLast ? 1 : 0); \
	if(pRspInfo && (pRspInfo->ErrorID != 0)) { \
		log_warn("%s | ErrorRsp | %d | %s", #fn, pRspInfo->ErrorID, pRspInfo->ErrorMsg); \
    } \
    ON_RSP_THEN_SEND(fn, tp); \
}

void CustomTradeSpi::OnRspSettlementInfoConfirm(
	CThostFtdcSettlementInfoConfirmField * pField,
	CThostFtdcRspInfoField *pRspInfo,
	int nRequestID,
	bool bIsLast)
{
	if (!isErrorRspInfo(pRspInfo)) {
		this->_trader->connected = 4;
		log_debug("OnRspSettlementInfoConfirm | Success | ConfirmDate:%s %s", pField->ConfirmDate, pField->ConfirmTime);
	}
	else {
		log_error("OnRspSettlementInfoConfirm | Failed | %d | %s", pRspInfo->ErrorID, pRspInfo->ErrorMsg);
	}

    ON_RSP_THEN_SEND(OnRspSettlementInfoConfirm, CThostFtdcSettlementInfoConfirmField);
}

CUSTOM_ON(OnRspQryTradingAccount, CThostFtdcTradingAccountField);
CUSTOM_ON(OnRspQryInvestorPosition, CThostFtdcInvestorPositionField);
CUSTOM_ON(OnRspQryInstrument, CThostFtdcInstrumentField);
CUSTOM_ON(OnRspOrderInsert, CThostFtdcInputOrderField);
CUSTOM_ON(OnRspOrderAction, CThostFtdcInputOrderActionField);
CUSTOM_ON(OnRspQryInstrumentMarginRate, CThostFtdcInstrumentMarginRateField);


void CustomTradeSpi::OnRspQryOrder(CThostFtdcOrderField * pField, CThostFtdcRspInfoField *pRspInfo, int nRequestID, bool bIsLast) {
    if(pField)
        log_debug("OnRspQryOrder %d | %s | %s+%s | %c", nRequestID, pField->InstrumentID, pField->ExchangeID, pField->OrderSysID, pField->OrderStatus);
    else 
        log_debug("OnRspQryOrder | Empty");
    ON_RSP_THEN_SEND(OnRspQryOrder, CThostFtdcOrderField);
}

void CustomTradeSpi::OnRtnOrder(CThostFtdcOrderField *pField)
{
    char submit_status[128];
    char order_status[128];
	// FrontID + SessionID + OrderRef
	strcpy(this->_trader->lst_order_ref, pField->OrderRef);

    switch (pField->OrderSubmitStatus) {
    case THOST_FTDC_OSS_InsertSubmitted:
        snprintf(submit_status, 128, "THOST_FTDC_OSS_InsertSubmitted");
        break;
    case THOST_FTDC_OSS_CancelSubmitted:
        snprintf(submit_status, 128, "THOST_FTDC_OSS_CancelSubmitted");
        break;
    case THOST_FTDC_OSS_ModifySubmitted:
        snprintf(submit_status, 128, "THOST_FTDC_OSS_ModifySubmitted");
        break;
    case THOST_FTDC_OSS_Accepted:
        snprintf(submit_status, 128, "THOST_FTDC_OSS_Accepted");
        break;
    case THOST_FTDC_OSS_InsertRejected:
        snprintf(submit_status, 128, "THOST_FTDC_OSS_InsertRejected");
        break;
    case THOST_FTDC_OSS_CancelRejected:
        snprintf(submit_status, 128, "THOST_FTDC_OSS_CancelRejected");
        break;
    case THOST_FTDC_OSS_ModifyRejected:
        snprintf(submit_status, 128, "THOST_FTDC_OSS_ModifyRejected");
        break;
    default:
        snprintf(submit_status, 128, "UNKNOWN_OrderSubmitStatus(%d)",
                 (int)(unsigned char)(pField->OrderSubmitStatus));
        break;
    }

    // order status
    switch (pField->OrderStatus) {
    case THOST_FTDC_OST_AllTraded:
        snprintf(order_status, 128, "AllTraded");
        break;
    case THOST_FTDC_OST_PartTradedQueueing:
        snprintf(order_status, 128, "PartTradedQueueing");
        break;
    case THOST_FTDC_OST_PartTradedNotQueueing:
        snprintf(order_status, 128, "PartTradedNotQueueing");
        break;
    case THOST_FTDC_OST_NoTradeQueueing:
        snprintf(order_status, 128, "NoTradeQueueing");
        break;
    case THOST_FTDC_OST_NoTradeNotQueueing:
        snprintf(order_status, 128, "NoTradeNotQueueing");
        break;
    case THOST_FTDC_OST_Canceled:
        snprintf(order_status, 128, "Canceled");
        break;
    case THOST_FTDC_OST_Unknown:
        snprintf(order_status, 128, "Unknown");
        break;
    case THOST_FTDC_OST_NotTouched:
        snprintf(order_status, 128, "NotTouched");
        break;
    case THOST_FTDC_OST_Touched:
        snprintf(order_status, 128, "Touched");
        break;
    default:
        snprintf(order_status, 128, "InvalidOrderStatus(%d)",
                 (int)(unsigned char)(pField->OrderStatus));
        break;
    }



	// ExchangeID + OrderSysID
	log_debug("OnRtnOrder | Ref: %d+%d+%s | Sys: %s+%s | %s | %lf | #:%d | #Traded: %d | Status | %s | %s", 
			pField->FrontID,
			pField->SessionID,
			pField->OrderRef,

			pField->ExchangeID,
			pField->OrderSysID,

			pField->InstrumentID,
			pField->LimitPrice,
			pField->VolumeTotal,
			pField->VolumeTraded,

            submit_status,
            order_status
		);

	ON_RSP_THEN_SEND_COMPACT(OnRtnOrder, CThostFtdcOrderField);
}

void CustomTradeSpi::OnRtnTrade(CThostFtdcTradeField *pField)
{
	log_debug("OnRtnTrade | Sys: %s+%s | %s | Time: %s %s | %lf | %d | %c",
			pField->ExchangeID,
			pField->OrderSysID,

			pField->InstrumentID,
			pField->TradeDate,
			pField->TradeTime,
			pField->Price,
			pField->Volume,
			pField->Direction
		);
	ON_RSP_THEN_SEND_COMPACT(OnRtnTrade, CThostFtdcTradeField);
}

void CustomTradeSpi::OnRspUserLogout(
	CThostFtdcUserLogoutField *pField,
	CThostFtdcRspInfoField *pRspInfo,
	int nRequestID,
	bool bIsLast)
{
	if (!isErrorRspInfo(pRspInfo))
	{
		log_debug("OnRspUserLogout | Success | BrokerID:%s | UserID:%s", this->_trader->broker, this->_trader->user);

        if(this->_trader->connected >= 2) {
            this->_trader->connected = 1; // connected, not logined
        }
	}

    ON_RSP_THEN_SEND(OnRspUserLogout, CThostFtdcUserLogoutField);
}

void CustomTradeSpi::OnRspUserPasswordUpdate(
    CThostFtdcUserPasswordUpdateField *pUserPasswordUpdate,
    CThostFtdcRspInfoField *pRspInfo,
    int nRequestID, bool bIsLast)
{
    if (pRspInfo && pRspInfo->ErrorID != 0) {
        // 改密失败
        std::cerr << "=== 密码修改失败 ===" << std::endl;
        std::cerr << "ErrorID: " << pRspInfo->ErrorID << std::endl;
        std::cerr << "ErrorMsg: " << pRspInfo->ErrorMsg << std::endl;

        switch (pRspInfo->ErrorID) {
        case 3:
            std::cerr << "原因: 旧密码错误" << std::endl;
            break;
        case 34:
            std::cerr << "原因: 新密码不符合复杂度要求" << std::endl;
            break;
        case 140:
            std::cerr << "原因: 新旧密码不能相同" << std::endl;
            break;
        default:
            break;
        }
    } else {
        std::cout << "=== 密码修改成功 ===" << std::endl;
        if (pUserPasswordUpdate) {
            std::cout << "BrokerID: " << pUserPasswordUpdate->BrokerID << std::endl;
            std::cout << "UserID: " << pUserPasswordUpdate->UserID << std::endl;
        }
        // 下次登录用新密码，当前会话不受影响
    }
}

bool CustomTradeSpi::isErrorRspInfo(CThostFtdcRspInfoField *pRspInfo)
{
	bool bResult = pRspInfo && (pRspInfo->ErrorID != 0);
	if (bResult)
		log_debug("isErrorRspInfo | %d | %s", pRspInfo->ErrorID, pRspInfo->ErrorMsg);
	return bResult;
}

int CustomTradeSpi::reqUserLogin()
{
	log_debug("reqUserLogin | %s | %s", this->_trader->broker, this->_trader->user);
	CThostFtdcReqUserLoginField loginReq;
	memset(&loginReq, 0, sizeof(loginReq));
	strcpy(loginReq.BrokerID, this->_trader->broker);
	strcpy(loginReq.UserID, this->_trader->user);
	strcpy(loginReq.Password, this->_trader->password);
	return ctp_trader_ReqUserLogin(this->_trader, &loginReq);
}


int CustomTradeSpi::reqSettlementInfoConfirm()
{
	log_debug("reqSettlementInfoConfirm");
	CThostFtdcSettlementInfoConfirmField settlementConfirmReq;
	memset(&settlementConfirmReq, 0, sizeof(settlementConfirmReq));
	strcpy(settlementConfirmReq.BrokerID, this->_trader->broker);
	strcpy(settlementConfirmReq.InvestorID, this->_trader->user);

	return ctp_trader_ReqSettlementInfoConfirm(this->_trader, &settlementConfirmReq);
}
