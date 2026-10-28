#include <iostream>
#include <fstream>
#include "malloc.h"
#include "string.h"
#include "time.h"
#include "CustomMdSpi.h"

extern "C" {
	#include "log.h"
}
// 连接成功应答
void CustomMdSpi::OnFrontConnected()
{
	log_debug("OnFrontConnected | %s", this->_md->front_addr);
	this->_md->connected = 1;
	// 开始登录
	CThostFtdcReqUserLoginField loginReq;
	memset(&loginReq, 0, sizeof(loginReq));
	strcpy(loginReq.BrokerID, this->_md->broker);
	strcpy(loginReq.UserID, this->_md->user);
	g_pMdUserApi->ReqUserLogin(&loginReq, 0);
}

// 断开连接通知
void CustomMdSpi::OnFrontDisconnected(int nReason)
{
	this->_md->connected = 0;
	log_warn("OnFrontDisconnected | Error: %d", nReason);
}

// 心跳超时警告
void CustomMdSpi::OnHeartBeatWarning(int nTimeLapse)
{
	this->_md->connected = 0;
	log_warn("OnHeartBeatWarning | nTimeLapse: %d", nTimeLapse);
}

// 登录应答
void CustomMdSpi::OnRspUserLogin(
	CThostFtdcRspUserLoginField *pRspUserLogin, 
	CThostFtdcRspInfoField *pRspInfo, 
	int nRequestID, 
	bool bIsLast)
{
	bool bResult = pRspInfo && (pRspInfo->ErrorID != 0);
	if (!bResult)
	{
		this->_md->connected = 2;
		log_debug("OnRspUserLogin | Success | BrokerID:%s | UserID:%s", this->_md->broker, this->_md->user);
	}
	else
		log_error("OnRspUserLogin | Fail | ErrorID:%d | %s", pRspInfo->ErrorID, pRspInfo->ErrorMsg);
}

// 登出应答
void CustomMdSpi::OnRspUserLogout(
	CThostFtdcUserLogoutField *pUserLogout,
	CThostFtdcRspInfoField *pRspInfo, 
	int nRequestID, 
	bool bIsLast)
{
	bool bResult = pRspInfo && (pRspInfo->ErrorID != 0);
	if (!bResult)
	{
		log_debug("OnRspUserLogout | Success");
	}
	else
		log_warn("OnRspUserLogout | Fail | ErrorID:%d", pRspInfo->ErrorID);
}

// 错误通知
void CustomMdSpi::OnRspError(CThostFtdcRspInfoField *pRspInfo, int nRequestID, bool bIsLast)
{
	bool bResult = pRspInfo && (pRspInfo->ErrorID != 0);
	if (bResult)
		log_error("OnRspError | ErrorID:%d | ErrorMsg:%s", pRspInfo->ErrorID, pRspInfo->ErrorMsg);
}

// 订阅行情应答
void CustomMdSpi::OnRspSubMarketData(
	CThostFtdcSpecificInstrumentField *pSpecificInstrument, 
	CThostFtdcRspInfoField *pRspInfo, 
	int nRequestID, 
	bool bIsLast)
{
    log_debug("OnRspSubMarketData | %s", pSpecificInstrument->InstrumentID);
	bool bResult = pRspInfo && (pRspInfo->ErrorID != 0);
	if (bResult) {
		log_error("OnRspError | ErrorID:%d | ErrorMsg:%s", pRspInfo->ErrorID, pRspInfo->ErrorMsg);
    }
    else {
        this->subscribed.insert(pSpecificInstrument->InstrumentID);
    }
}

// 取消订阅行情应答
void CustomMdSpi::OnRspUnSubMarketData(
	CThostFtdcSpecificInstrumentField *pSpecificInstrument, 
	CThostFtdcRspInfoField *pRspInfo,
	int nRequestID, 
	bool bIsLast)
{
    log_debug("OnRspUnSubMarketData | %s", pSpecificInstrument->InstrumentID);
	bool bResult = pRspInfo && (pRspInfo->ErrorID != 0);
	if (bResult) {
		log_error("OnRspError | ErrorID:%d | ErrorMsg:%s", pRspInfo->ErrorID, pRspInfo->ErrorMsg);
    }
    else {
        subscribed.erase(pSpecificInstrument->InstrumentID);
    }
}

// 订阅询价应答
void CustomMdSpi::OnRspSubForQuoteRsp(
	CThostFtdcSpecificInstrumentField *pSpecificInstrument,
	CThostFtdcRspInfoField *pRspInfo,
	int nRequestID,
	bool bIsLast)
{
	bool bResult = pRspInfo && (pRspInfo->ErrorID != 0);
	if (!bResult)
	{
		log_debug("OnRspSubForQuoteRsp | Success | InstrumentID:%s", pSpecificInstrument->InstrumentID);
	}
	else
		log_error("OnRspSubForQuoteRsp | Fail | ErrorID:%d", pRspInfo->ErrorID);
}

// 取消订阅询价应答
void CustomMdSpi::OnRspUnSubForQuoteRsp(CThostFtdcSpecificInstrumentField *pSpecificInstrument, CThostFtdcRspInfoField *pRspInfo, int nRequestID, bool bIsLast)
{
	bool bResult = pRspInfo && (pRspInfo->ErrorID != 0);
	if (!bResult)
	{
		log_debug("OnRspUnSubForQuoteRsp | Success | InstrumentID:%s", pSpecificInstrument->InstrumentID);
	}
	else
		log_error("OnRspUnSubForQuoteRsp | Fail | ErrorID:%d", pRspInfo->ErrorID);
}

// 行情详情通知
void CustomMdSpi::OnRtnDepthMarketData(CThostFtdcDepthMarketDataField *pDepthMarketData)
{
	CThostFtdcDepthMarketDataField * data = (CThostFtdcDepthMarketDataField *)malloc(sizeof(CThostFtdcDepthMarketDataField));
	memcpy(data, pDepthMarketData, sizeof(CThostFtdcDepthMarketDataField));

	ctp_md_send(this->_md, (void*)data);}

// 询价详情通知
void CustomMdSpi::OnRtnForQuoteRsp(CThostFtdcForQuoteRspField *pForQuoteRsp)
{
}