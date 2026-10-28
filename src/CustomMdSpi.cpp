#include <stdio.h>
#include "string.h"
#include "CustomMdSpi.h"

extern "C" {
	#include "log.h"
}

// Copy a callback's arguments into one message and queue it for Lua.
static void send_md(ctp_md_t * md, const char * fn, const char * field_name, uint32_t typ,
	int req_id, bool is_last, const void * field, size_t size, const CThostFtdcRspInfoField * info)
{
	ctp_rsp_t * rsp = ctp_rsp_new(fn, field_name, req_id, is_last, field, size,
		info, sizeof(CThostFtdcRspInfoField));
	if (rsp == NULL) {
		log_error("%s | out of memory, message dropped", fn);
		return;
	}
	rsp->rsp_typ = typ;
	ctp_md_send(md, rsp);
}

// An event whose only payload is an error code and message made up here.
static void send_md_error(ctp_md_t * md, const char * fn, int error_id, const char * msg)
{
	CThostFtdcRspInfoField info;
	memset(&info, 0, sizeof(info));
	info.ErrorID = error_id;
	snprintf(info.ErrorMsg, sizeof(info.ErrorMsg), "%s", msg);
	send_md(md, fn, "", CTPC_RSP_EVENT, -1, true, NULL, 0, &info);
}

static void set_state(ctp_md_t * md, int state)
{
	__atomic_store_n(&md->state, state, __ATOMIC_RELEASE);
}

static bool is_error(const CThostFtdcRspInfoField * info)
{
	return info != NULL && info->ErrorID != 0;
}

// 连接成功应答：自动登录，重连后也一样
void CustomMdSpi::OnFrontConnected()
{
	log_debug("OnFrontConnected | %s", this->_md->front_addr);
	set_state(this->_md, CTPC_MD_CONNECTED);
	send_md(this->_md, "OnFrontConnected", "", CTPC_RSP_EVENT, -1, true, NULL, 0, NULL);

	CThostFtdcReqUserLoginField loginReq;
	memset(&loginReq, 0, sizeof(loginReq));
	strcpy(loginReq.BrokerID, this->_md->broker);
	strcpy(loginReq.UserID, this->_md->user);
	int rc = g_pMdUserApi->ReqUserLogin(&loginReq, 0);
	if (rc != 0) {
		// no response will come; report the failure as one
		char msg[64];
		snprintf(msg, sizeof(msg), "ReqUserLogin failed (%d)", rc);
		log_error("OnFrontConnected | %s", msg);
		send_md_error(this->_md, "OnRspUserLogin", rc < 0 ? rc : -rc, msg);
	}
}

// 断开连接通知：CTP 会自动重连，之后再走 OnFrontConnected
void CustomMdSpi::OnFrontDisconnected(int nReason)
{
	const char * reason;
	switch (nReason) {
	case 0x1001: reason = "network read failed"; break;
	case 0x1002: reason = "network write failed"; break;
	case 0x2001: reason = "heartbeat timeout"; break;
	case 0x2002: reason = "heartbeat send failed"; break;
	case 0x2003: reason = "bad packet received"; break;
	default: reason = "unknown reason"; break;
	}
	char msg[64];
	snprintf(msg, sizeof(msg), "disconnected: %s (0x%x)", reason, nReason);
	log_warn("OnFrontDisconnected | %s", msg);
	set_state(this->_md, CTPC_MD_DISCONNECTED);
	send_md_error(this->_md, "OnFrontDisconnected", nReason, msg);
}

// 心跳超时警告：只是警告，连接仍在；真断开时会有 OnFrontDisconnected
void CustomMdSpi::OnHeartBeatWarning(int nTimeLapse)
{
	log_warn("OnHeartBeatWarning | nTimeLapse: %d", nTimeLapse);
}

// 登录应答
void CustomMdSpi::OnRspUserLogin(
	CThostFtdcRspUserLoginField *pRspUserLogin,
	CThostFtdcRspInfoField *pRspInfo,
	int nRequestID,
	bool bIsLast)
{
	if (!is_error(pRspInfo))
	{
		set_state(this->_md, CTPC_MD_LOGGED_IN);
		log_debug("OnRspUserLogin | Success | BrokerID:%s | UserID:%s", this->_md->broker, this->_md->user);
	}
	else
		log_error("OnRspUserLogin | Fail | ErrorID:%d | %s", pRspInfo->ErrorID, pRspInfo->ErrorMsg);
	send_md(this->_md, "OnRspUserLogin", "CThostFtdcRspUserLoginField", CTPC_RSP_EVENT,
		nRequestID, bIsLast, pRspUserLogin, sizeof(CThostFtdcRspUserLoginField), pRspInfo);
}

// 登出应答
void CustomMdSpi::OnRspUserLogout(
	CThostFtdcUserLogoutField *pUserLogout,
	CThostFtdcRspInfoField *pRspInfo,
	int nRequestID,
	bool bIsLast)
{
	if (!is_error(pRspInfo))
	{
		log_debug("OnRspUserLogout | Success");
	}
	else
		log_warn("OnRspUserLogout | Fail | ErrorID:%d", pRspInfo->ErrorID);
}

// 错误通知
void CustomMdSpi::OnRspError(CThostFtdcRspInfoField *pRspInfo, int nRequestID, bool bIsLast)
{
	if (is_error(pRspInfo))
		log_error("OnRspError | ErrorID:%d | ErrorMsg:%s", pRspInfo->ErrorID, pRspInfo->ErrorMsg);
	send_md(this->_md, "OnRspError", "", CTPC_RSP_EVENT, nRequestID, bIsLast, NULL, 0, pRspInfo);
}

// 订阅行情应答
void CustomMdSpi::OnRspSubMarketData(
	CThostFtdcSpecificInstrumentField *pSpecificInstrument,
	CThostFtdcRspInfoField *pRspInfo,
	int nRequestID,
	bool bIsLast)
{
	const char * symbol = pSpecificInstrument ? pSpecificInstrument->InstrumentID : "";
	if (is_error(pRspInfo))
		log_error("OnRspSubMarketData | %s | ErrorID:%d | ErrorMsg:%s", symbol, pRspInfo->ErrorID, pRspInfo->ErrorMsg);
	else
		log_debug("OnRspSubMarketData | %s", symbol);
	send_md(this->_md, "OnRspSubMarketData", "CThostFtdcSpecificInstrumentField", CTPC_RSP_EVENT,
		nRequestID, bIsLast, pSpecificInstrument, sizeof(CThostFtdcSpecificInstrumentField), pRspInfo);
}

// 取消订阅行情应答
void CustomMdSpi::OnRspUnSubMarketData(
	CThostFtdcSpecificInstrumentField *pSpecificInstrument,
	CThostFtdcRspInfoField *pRspInfo,
	int nRequestID,
	bool bIsLast)
{
	const char * symbol = pSpecificInstrument ? pSpecificInstrument->InstrumentID : "";
	if (is_error(pRspInfo))
		log_error("OnRspUnSubMarketData | %s | ErrorID:%d | ErrorMsg:%s", symbol, pRspInfo->ErrorID, pRspInfo->ErrorMsg);
	else
		log_debug("OnRspUnSubMarketData | %s", symbol);
	send_md(this->_md, "OnRspUnSubMarketData", "CThostFtdcSpecificInstrumentField", CTPC_RSP_EVENT,
		nRequestID, bIsLast, pSpecificInstrument, sizeof(CThostFtdcSpecificInstrumentField), pRspInfo);
}

// 订阅询价应答
void CustomMdSpi::OnRspSubForQuoteRsp(
	CThostFtdcSpecificInstrumentField *pSpecificInstrument,
	CThostFtdcRspInfoField *pRspInfo,
	int nRequestID,
	bool bIsLast)
{
	const char * symbol = pSpecificInstrument ? pSpecificInstrument->InstrumentID : "";
	if (!is_error(pRspInfo))
	{
		log_debug("OnRspSubForQuoteRsp | Success | InstrumentID:%s", symbol);
	}
	else
		log_error("OnRspSubForQuoteRsp | Fail | ErrorID:%d", pRspInfo->ErrorID);
}

// 取消订阅询价应答
void CustomMdSpi::OnRspUnSubForQuoteRsp(CThostFtdcSpecificInstrumentField *pSpecificInstrument, CThostFtdcRspInfoField *pRspInfo, int nRequestID, bool bIsLast)
{
	const char * symbol = pSpecificInstrument ? pSpecificInstrument->InstrumentID : "";
	if (!is_error(pRspInfo))
	{
		log_debug("OnRspUnSubForQuoteRsp | Success | InstrumentID:%s", symbol);
	}
	else
		log_error("OnRspUnSubForQuoteRsp | Fail | ErrorID:%d", pRspInfo->ErrorID);
}

// 行情详情通知
void CustomMdSpi::OnRtnDepthMarketData(CThostFtdcDepthMarketDataField *pDepthMarketData)
{
	send_md(this->_md, "OnRtnDepthMarketData", "CThostFtdcDepthMarketDataField", CTPC_RSP_TICK,
		-1, true, pDepthMarketData, sizeof(CThostFtdcDepthMarketDataField), NULL);
}

// 询价详情通知
void CustomMdSpi::OnRtnForQuoteRsp(CThostFtdcForQuoteRspField *pForQuoteRsp)
{
}
