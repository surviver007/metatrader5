//+------------------------------------------------------------------+
//|                                              GridMasterPro.mq5   |
//|                                    Copyright 2026, wangxiaozhi.  |
//|                                           https://www.mql5.com   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, wangxiaozhi."
#property link      "https://www.mql5.com"
#property version   "4.0"
#property strict
#property description "单根阳线/阴线形态 + 动态间距加仓策略（固定点数止盈）"

#include <Trade\Trade.mqh>

sinput string _grp1 = "交易设置"; // ===== 交易设置 =====
input double         InitialLot       = 0.01;           // 固定初始手数（UseDynamicLot=false时生效）
input bool           UseDynamicLot    = true;           // 启用动态手数（按余额比例）
input double         RiskPercent      = 1.0;            // 动态手数：余额风险百分比
input int            FlatAddCount     = 9;              // 前N笔等量加仓（之后启用加仓模式）

sinput string _grp2 = "加仓模式"; // ===== 加仓模式 =====
enum ENUM_ADD_MODE {
    ADD_MARTIN   = 0,    // 马丁格尔（上一笔手数 × 倍数）
    ADD_FIBONACCI = 1    // 斐波那契（最远两笔手数之和）
};
input ENUM_ADD_MODE  AddMode          = ADD_MARTIN;     // 加仓手数模式
input double         MartinMultiplier = 1.3;            // 马丁格尔倍数（上一笔手数 × 此值）
input int            MaxPositions     = 50;             // 单方向最大持仓数
input double         ATRAddMultiplier = 1.0;            // 加仓间距基础ATR倍数
input double         ATRStepIncrement = 0.2;            // 加仓间距递增（每多一笔增加ATR倍数）
input double         StopBufferATRRatio = 0.2;          // 挂单缓冲ATR倍数（挂单价=当前价±ATR×此值，0=无缓冲）
input int            PendingMinLiveSec = 1;              // 挂单最小存活秒数（创建后至少存活N秒才允许撤单更新）
input int            CooldownBars     = 20;             // 回撤恢复后冷却K线数
input int            ATRPeriod        = 2;              // ATR周期
input double         MinBodyATRRatio  = 0.5;            // 入场K线最小实体/ATR比例（最近一根阳线/阴线实体≥ATR×此值）

sinput string _grp3 = "布林带加仓过滤"; // ===== 布林带加仓过滤 =====
input int            BBPeriod         = 20;             // 布林带周期
input double         BBDeviation      = 2.0;            // 布林带标准差倍数

sinput string _grp4 = "止盈设置"; // ===== 止盈设置 =====
input double         ProfitPerPositionUSD = 2.0;       // 每笔持仓目标盈利（USD），N笔持仓盈利≥N×此值时平仓

sinput string _grp5 = "风控管理"; // ===== 风控管理 =====
input double         MaxDrawdownPct   = 30.0;           // 最大回撤百分比
input int            MaxSpreadPoints  = 50;             // 最大点差（点）
input bool           AllowBuy         = true;           // 允许做多
input bool           AllowSell        = false;          // 允许做空
input int            MagicBase        = 47291;          // 魔术号
input bool           DebugMode        = false;          // 调试模式

sinput string _grp6 = "趋势对冲策略"; // ===== 趋势对冲策略 =====
input bool           EnableTrendStrategy      = false;   // 启用趋势对冲策略
input int            TrendMaxAdds             = 10;       // 最大加仓次数（不含初始入场）
input double         TrendAddATRMultiplier    = 1.0;     // 加仓间距ATR倍数
input double         TrendTrailATRMultiplier  = 3.0;     // 追踪止盈ATR倍数
input double         TrendLotMultiplier       = 1.0;     // 趋势手数倍数（相对动态手数）

//--- 全局变量
CTrade   trade;
int      magicNumber;
double   accountEquityStart;
string   logFile;
int      atrHandle;
int      bbHandle;
int      symbolDigits;
double   symbolPoint;
datetime cooldownUntil;
datetime lastBarTime;
int      trendMagicNumber;     // 趋势策略魔术号
datetime trendLastBarTime;     // 趋势策略新K线检测
double   trendBuyPeakPrice;    // 趋势做多追踪峰值价
double   trendSellPeakPrice;   // 趋势做空追踪谷值价

//--- 挂单识别前缀
string PENDING_COMMENT_BUY  = "GRID BUYSTOP";
string PENDING_COMMENT_SELL = "GRID SELLSTOP";
datetime pendingBuyCreateTime;   // 多头挂单创建时间
datetime pendingSellCreateTime;  // 空头挂单创建时间

//+------------------------------------------------------------------+
//| EA 初始化                                                        |
//+------------------------------------------------------------------+
int OnInit() {
    // 防冲突魔术号
    int symbolHash = 0;
    for (int i = 0; i < (int)StringLen(_Symbol); i++)
        symbolHash = (symbolHash * 31 + (int)StringGetCharacter(_Symbol, i)) & 0x7FFF;
    magicNumber = MagicBase + symbolHash + (int)Period();
    trade.SetExpertMagicNumber(magicNumber);
    trade.SetDeviationInPoints(50);
    trade.SetTypeFilling(DetectFillType());

    symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    symbolPoint  = _Point;

    accountEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
    logFile     = "GridMasterPro_" + _Symbol + "_" + IntegerToString(Period()) + ".log";

    // 创建 ATR 指标句柄
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
    if (atrHandle == INVALID_HANDLE) {
        WriteLog("FAILED to create ATR indicator handle");
        return INIT_FAILED;
    }

    // 创建布林带指标句柄
    bbHandle = iBands(_Symbol, PERIOD_CURRENT, BBPeriod, 0, BBDeviation, PRICE_CLOSE);
    if (bbHandle == INVALID_HANDLE) {
        WriteLog("FAILED to create Bollinger Bands indicator handle");
        return INIT_FAILED;
    }

    lastBarTime = 0;

    // 趋势策略初始化
    trendMagicNumber = MagicBase + 100000 + symbolHash + (int)Period();
    trendLastBarTime = 0;
    trendBuyPeakPrice = 0;
    trendSellPeakPrice = 0;

    string addModeStr = (AddMode == ADD_MARTIN) ?
                         "Martin x" + DoubleToString(MartinMultiplier, 1) : "Fibonacci";
    WriteLog("GridMaster Pro v4.0 initialized | Magic: " + IntegerToString(magicNumber) +
             " | TrendMagic: " + IntegerToString(trendMagicNumber) +
             " | Symbol: " + _Symbol + " | Strategy: 2-Candle Pattern + Dynamic Grid + Fixed TP" +
             " | AddMode: " + addModeStr + " after " + IntegerToString(FlatAddCount) + " flat" +
             " | MinBodyATR: " + DoubleToString(MinBodyATRRatio, 2) +
             " | BB: " + IntegerToString(BBPeriod) + " / " + DoubleToString(BBDeviation, 1) +
             " | ProfitTP: " + DoubleToString(ProfitPerPositionUSD, 2) + " USD/pos" +
             " | DynamicLot: " + (UseDynamicLot ? "ON " + DoubleToString(RiskPercent, 1) + "%" : "OFF") +
             " | Trend: " + (EnableTrendStrategy ? "ON BB=" + IntegerToString(BBPeriod) + "/" + DoubleToString(BBDeviation, 1) +
                " MaxAdds=" + IntegerToString(TrendMaxAdds) +
                " TrailATR=" + DoubleToString(TrendTrailATRMultiplier, 1) : "OFF"));

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EA 反初始化                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    CancelAllPendingOrders();
    if (atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if (bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
    WriteLog("EA deinitialized. Reason: " + IntegerToString(reason) +
             " | Grid: " + IntegerToString(CountPositions(POSITION_TYPE_BUY) + CountPositions(POSITION_TYPE_SELL)) +
             " | Trend: " + IntegerToString(CountTrendPositions(POSITION_TYPE_BUY) + CountTrendPositions(POSITION_TYPE_SELL)));
}

//+------------------------------------------------------------------+
//| EA Tick 函数                                                     |
//+------------------------------------------------------------------+
void OnTick() {
    if (!IsMarketActive()) return;

    // --- 高水位更新 ---
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    if (currentEquity > accountEquityStart)
        accountEquityStart = currentEquity;

    // --- 回撤保护 ---
    if (CheckDrawdown()) {
        WriteLog("DRAWDOWN LIMIT REACHED — closing all positions");
        CloseAllPositions();
        if (EnableTrendStrategy) CloseTrendPositions();
        accountEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
        cooldownUntil = iTime(_Symbol, PERIOD_CURRENT, 0) + CooldownBars * PeriodSeconds(PERIOD_CURRENT);
        WriteLog("Drawdown recovery — equity baseline reset to " + DoubleToString(accountEquityStart, 2) +
                 " | Cooldown until: " + TimeToString(cooldownUntil));
        return;
    }

    // --- 点差过滤 ---
    if ((long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints) return;

    // --- 读取ATR ---
    double atrVal[];
    ArraySetAsSeries(atrVal, true);
    if (CopyBuffer(atrHandle, 0, 0, 2, atrVal) <= 0) return;
    double atr = atrVal[1];   // 使用已完成K线的ATR

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // --- 1. 固定点数止盈检查 ---
    CheckFixedTP(POSITION_TYPE_BUY);
    CheckFixedTP(POSITION_TYPE_SELL);

    // --- 3. 冷却期检查 ---
    bool inCooldown = (cooldownUntil > 0 && iTime(_Symbol, PERIOD_CURRENT, 0) < cooldownUntil);

    // --- 4. 新K线检测（避免同根K线重复入场） ---
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    bool newGridBar = (currentBarTime != lastBarTime);
    if (newGridBar) lastBarTime = currentBarTime;

    // --- 5. 网格策略：K线形态入场（仅新K线） ---
    if (newGridBar) {
        double open1  = iOpen(_Symbol, PERIOD_CURRENT, 1);
        double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
        double body1  = MathAbs(close1 - open1);
        bool   isBull1 = (close1 > open1);   // bar[1] 阳线
        bool   isBear1 = (open1 > close1);   // bar[1] 阴线
        bool   body1Strong = (atr > 0 && body1 >= atr * MinBodyATRRatio);  // bar[1]实体够大
        bool   oneBull = (isBull1 && body1Strong);  // 单根阳线且实体够大
        bool   oneBear = (isBear1 && body1Strong);  // 单根阴线且实体够大

        int buyCount  = CountPositions(POSITION_TYPE_BUY);
        int sellCount = CountPositions(POSITION_TYPE_SELL);

        // 做多：单根阳线实体够大，且当前无多头持仓
        if (!inCooldown && AllowBuy && oneBull && buyCount == 0) {
            double lot = CalcDynamicLot();
            if (CheckMargin(ORDER_TYPE_BUY, ask, lot)) {
                if (trade.Buy(lot, _Symbol, ask, 0, 0, "CANDLE BUY #1")) {
                    WriteLog("CANDLE BUY #1 | Price: " + DoubleToString(ask, symbolDigits) +
                             " | Body: " + DoubleToString(body1, symbolDigits) +
                             " | ATR: " + DoubleToString(atr, symbolDigits) +
                             " | Lot: " + DoubleToString(lot, 2));
                }
            }
        }

        // 做空：单根阴线实体够大，且当前无空头持仓
        if (!inCooldown && AllowSell && oneBear && sellCount == 0) {
            double lot = CalcDynamicLot();
            if (CheckMargin(ORDER_TYPE_SELL, bid, lot)) {
                if (trade.Sell(lot, _Symbol, bid, 0, 0, "CANDLE SELL #1")) {
                    WriteLog("CANDLE SELL #1 | Price: " + DoubleToString(bid, symbolDigits) +
                             " | Body: " + DoubleToString(body1, symbolDigits) +
                             " | ATR: " + DoubleToString(atr, symbolDigits) +
                             " | Lot: " + DoubleToString(lot, 2));
                }
            }
        }
    }

    // --- 6. 网格策略：马丁格尔加仓（每个tick） ---
    if (atr > 0) {
        if (AllowBuy)  CheckMartingale(POSITION_TYPE_BUY, ask, atr);
        if (AllowSell) CheckMartingale(POSITION_TYPE_SELL, bid, atr);
    }

    // --- 7. 趋势对冲策略（如果启用） ---
    if (EnableTrendStrategy && atr > 0) {
        CheckTrendTrailStop(POSITION_TYPE_BUY, bid, atr);
        CheckTrendTrailStop(POSITION_TYPE_SELL, bid, atr);
        bool newTrendBar = (currentBarTime != trendLastBarTime);
        if (newTrendBar) {
            trendLastBarTime = currentBarTime;
            CheckTrendBreakout(ask, bid, atr);
            CheckTrendAdd(POSITION_TYPE_BUY, ask, atr);
            CheckTrendAdd(POSITION_TYPE_SELL, bid, atr);
        }
    }
}

//+------------------------------------------------------------------+
//| 美元盈利止盈：N笔持仓总盈利≥N×ProfitPerPositionUSD时平掉所有持仓 |
//+------------------------------------------------------------------+
void CheckFixedTP(ENUM_POSITION_TYPE dir) {
    int count = CountPositions(dir);
    if (count <= 0) return;

    double profit = GetTotalProfit(dir);
    double target = count * ProfitPerPositionUSD;

    if (profit >= target) {
        double avgEntry = GetAvgEntryPrice(dir);
        ClosePositionsByType(dir);
        CancelPendingOrders(dir);
        string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        WriteLog("PROFIT TP " + dirStr + " | Positions: " + IntegerToString(count) +
                 " | AvgEntry: " + DoubleToString(avgEntry, symbolDigits) +
                 " | Profit: " + DoubleToString(profit, 2) +
                 " USD | Target: " + DoubleToString(target, 2) +
                 " USD (=" + IntegerToString(count) + " x " +
                 DoubleToString(ProfitPerPositionUSD, 2) + ")");
    }
}

//+------------------------------------------------------------------+
//| 马丁格尔加仓：亏损时在动态ATR距离处挂突破单（BUY STOP / SELL STOP） |
//+------------------------------------------------------------------+
void CheckMartingale(ENUM_POSITION_TYPE dir, double currentPrice, double atr) {
    int count = CountPositions(dir);
    if (count <= 0 || count >= MaxPositions) return;

    // 已盈利时取消挂单，不新建
    if (GetTotalProfit(dir) >= 0) {
        if (CountPendingOrders(dir) > 0) {
            CancelPendingOrders(dir);
            string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";
            WriteLog("PENDING CANCEL (profit) " + dirStr + " | positions profitable, removing pending order");
        }
        return;
    }

    // 获取最远入场价（做多取最低价，做空取最高价）
    double extremePrice = GetExtremeEntryPrice(dir);
    if (extremePrice <= 0) return;

    // --- 已有挂单：检查是否需要更新价格 ---
    if (CountPendingOrders(dir) > 0) {
        ulong pendingTicket = GetPendingOrderTicket(dir);
        if (pendingTicket > 0) {
            // 挂单创建不足PendingMinLiveSec秒时不撤单，避免频繁操作
            datetime createTime = (dir == POSITION_TYPE_BUY) ? pendingBuyCreateTime : pendingSellCreateTime;
            if (TimeCurrent() - createTime < PendingMinLiveSec) return;

            // 计算期望的挂单价（基于当前价格）
            double buffer = atr * StopBufferATRRatio;
            double expectedStopPrice;
            if (dir == POSITION_TYPE_BUY)
                expectedStopPrice = NormalizeDouble(currentPrice + buffer, symbolDigits);
            else
                expectedStopPrice = NormalizeDouble(currentPrice - buffer, symbolDigits);

            double currentStopPrice = OrderGetDouble(ORDER_PRICE_OPEN);
            // 价格差异超过最小变动价位的 1 倍时更新
            if (MathAbs(currentStopPrice - expectedStopPrice) > symbolPoint) {
                trade.OrderDelete(pendingTicket);
                string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";
                WriteLog("PENDING UPDATE " + dirStr + " | old price: " + DoubleToString(currentStopPrice, symbolDigits) +
                         " -> new price: " + DoubleToString(expectedStopPrice, symbolDigits) +
                         " | currentPrice changed");
                // 删除后会在下面的逻辑中重新创建
            } else {
                return; // 挂单价格正确，无需操作
            }
        }
        return;
    }

    // --- 无挂单：检查是否需要创建 ---

    // 动态间距：持仓越多，间距越大
    double currentMultiplier = ATRAddMultiplier + (count - 1) * ATRStepIncrement;
    double addDistance = atr * currentMultiplier;
    bool shouldAdd = false;

    if (dir == POSITION_TYPE_BUY)
        shouldAdd = (currentPrice <= extremePrice - addDistance);
    else
        shouldAdd = (currentPrice >= extremePrice + addDistance);

    if (!shouldAdd) return;

    // --- 布林带过滤：价格超出布林带外轨时不加仓，避免强趋势中逆势加仓 ---
    double bbUpper[], bbLower[];
    ArraySetAsSeries(bbUpper, true);
    ArraySetAsSeries(bbLower, true);
    if (CopyBuffer(bbHandle, 1, 0, 2, bbUpper) <= 0 ||
        CopyBuffer(bbHandle, 2, 0, 2, bbLower) <= 0) return;
    double upperBand = bbUpper[1];
    double lowerBand = bbLower[1];

    if (dir == POSITION_TYPE_BUY) {
        // 多头加仓：价格在下轨下方（强下跌趋势），禁止加仓
        if (currentPrice < lowerBand) {
            if (DebugMode) WriteLog("BUY ADD blocked — price below BB lower band (" +
                     DoubleToString(lowerBand, symbolDigits) + ")");
            return;
        }
    } else {
        // 空头加仓：价格在上轨上方（强上涨趋势），禁止加仓
        if (currentPrice > upperBand) {
            if (DebugMode) WriteLog("SELL ADD blocked — price above BB upper band (" +
                     DoubleToString(upperBand, symbolDigits) + ")");
            return;
        }
    }

    // 加仓手数计算：前 FlatAddCount 笔等量，之后按选定模式递增
    double newLot;
    string addModeStr;
    if (count < FlatAddCount) {
        // 等量加仓
        newLot = CalcDynamicLot();
        addModeStr = "FLAT";
    } else if (AddMode == ADD_MARTIN) {
        // 马丁格尔：取最近一笔的手数 × 倍数
        double lastLot = GetLastLot(dir);
        newLot = NormalizeLot(lastLot * MartinMultiplier);
        // 确保 NormalizeLot 向下取整后至少增加一个步长
        if (newLot <= lastLot)
            newLot = NormalizeLot(lastLot + SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
        addModeStr = "MARTIN x" + DoubleToString(MartinMultiplier, 1);
    } else {
        // 斐波那契：最远两笔手数之和
        double lot1, lot2;
        GetTwoExtremeLots(dir, lot1, lot2);
        newLot = NormalizeLot(lot1 + lot2);
        double lastLot = GetLastLot(dir);
        if (newLot <= lastLot)
            newLot = NormalizeLot(lastLot + SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
        addModeStr = "FIB";
    }

    // 计算挂单价格（基于当前价格，在当前价格上方/下方挂突破单）
    double buffer = atr * StopBufferATRRatio;
    double stopPrice;
    if (dir == POSITION_TYPE_BUY)
        stopPrice = NormalizeDouble(currentPrice + buffer, symbolDigits);
    else
        stopPrice = NormalizeDouble(currentPrice - buffer, symbolDigits);

    // 验证挂单价合法性
    if (!IsValidStopOrderPrice(dir, stopPrice)) {
        if (DebugMode) {
            string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";
            WriteLog("PENDING " + dirStr + " blocked — invalid stop price: " +
                     DoubleToString(stopPrice, symbolDigits));
        }
        return;
    }

    ENUM_ORDER_TYPE orderType = (dir == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    if (!CheckMargin(orderType, stopPrice, newLot)) {
        if (DebugMode) WriteLog("Insufficient margin for " + addModeStr + " pending add");
        return;
    }

    string comment = ((dir == POSITION_TYPE_BUY) ? PENDING_COMMENT_BUY + " #" : PENDING_COMMENT_SELL + " #") +
                     IntegerToString(count + 1);

    bool sent = false;
    if (dir == POSITION_TYPE_BUY)
        sent = trade.BuyStop(newLot, stopPrice, _Symbol, 0, 0, 0, 0, comment);
    else
        sent = trade.SellStop(newLot, stopPrice, _Symbol, 0, 0, 0, 0, comment);

    if (sent) {
        // 记录挂单创建时间
        if (dir == POSITION_TYPE_BUY) pendingBuyCreateTime = TimeCurrent();
        else pendingSellCreateTime = TimeCurrent();

        string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        WriteLog(addModeStr + " PENDING " + dirStr + " STOP #" + IntegerToString(count + 1) +
                 " | StopPrice: " + DoubleToString(stopPrice, symbolDigits) +
                 " | CurrentPrice: " + DoubleToString(currentPrice, symbolDigits) +
                 " | Lot: " + DoubleToString(newLot, 2) +
                 " | ATR x" + DoubleToString(currentMultiplier, 1) +
                 " | Distance: " + DoubleToString(addDistance, symbolDigits) +
                 " | Buffer: " + DoubleToString(buffer, symbolDigits) +
                 " | Positions: " + IntegerToString(count));
    }
}

//+------------------------------------------------------------------+
//| 检测经纪商支持的成交类型                                          |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillType() {
    long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    if ((fillMode & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    if ((fillMode & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
    return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| 检查市场是否活跃且允许交易                                       |
//+------------------------------------------------------------------+
bool IsMarketActive() {
    if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
    if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;

    long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
    if (tradeMode != SYMBOL_TRADE_MODE_FULL) return false;

    // 周末检查（加密货币等品种跳过）
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if (dt.day_of_week == 0 || dt.day_of_week == 6) {
        string sym = _Symbol;
        if (StringFind(sym, "BTC") < 0 && StringFind(sym, "ETH") < 0 &&
            StringFind(sym, "XRP") < 0 && StringFind(sym, "LTC") < 0 &&
            StringFind(sym, "SOL") < 0 && StringFind(sym, "DOGE") < 0)
            return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| 标准化手数                                                       |
//+------------------------------------------------------------------+
double NormalizeLot(double lot) {
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / lotStep) * lotStep;
    lot = MathMax(minLot, MathMin(maxLot, lot));
    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| 动态手数计算（按账户余额比例）                                    |
//+------------------------------------------------------------------+
double CalcDynamicLot() {
    if (!UseDynamicLot) return NormalizeLot(InitialLot);

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double marginForOneLot;
    if (!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0,
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginForOneLot))
        return NormalizeLot(InitialLot);

    if (marginForOneLot <= 0) return NormalizeLot(InitialLot);

    double lot = balance * RiskPercent / 100.0 / marginForOneLot;
    return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| 保证金检查                                                       |
//+------------------------------------------------------------------+
bool CheckMargin(ENUM_ORDER_TYPE type, double price, double lot) {
    double margin;
    if (!OrderCalcMargin(type, _Symbol, lot, price, margin)) return false;
    double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    return margin <= freeMargin * 0.95;
}

//+------------------------------------------------------------------+
//| 按方向统计持仓数量                                               |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE posType) {
    int count = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
            count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| 获取最远入场价（做多=最低价，做空=最高价）                       |
//+------------------------------------------------------------------+
double GetExtremeEntryPrice(ENUM_POSITION_TYPE posType) {
    double result = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

        double p = PositionGetDouble(POSITION_PRICE_OPEN);
        if (posType == POSITION_TYPE_BUY) {
            if (result == 0 || p < result) result = p;
        } else {
            if (result == 0 || p > result) result = p;
        }
    }
    return result;
}

//+------------------------------------------------------------------+
//| 获取持仓加权平均入场价                                           |
//+------------------------------------------------------------------+
double GetAvgEntryPrice(ENUM_POSITION_TYPE posType) {
    double totalCost   = 0;
    double totalVolume = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;
        double p   = PositionGetDouble(POSITION_PRICE_OPEN);
        double lot = PositionGetDouble(POSITION_VOLUME);
        totalCost   += p * lot;
        totalVolume += lot;
    }
    if (totalVolume <= 0) return 0;
    return totalCost / totalVolume;
}

//+------------------------------------------------------------------+
//| 获取最远入场价的持仓手数                                         |
//+------------------------------------------------------------------+
double GetExtremeEntryLot(ENUM_POSITION_TYPE posType) {
    double extremePrice = 0;
    double extremeLot   = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

        double p   = PositionGetDouble(POSITION_PRICE_OPEN);
        double lot = PositionGetDouble(POSITION_VOLUME);

        if (posType == POSITION_TYPE_BUY) {
            if (extremePrice == 0 || p < extremePrice) {
                extremePrice = p;
                extremeLot   = lot;
            }
        } else {
            if (extremePrice == 0 || p > extremePrice) {
                extremePrice = p;
                extremeLot   = lot;
            }
        }
    }
    return extremeLot;
}

//+------------------------------------------------------------------+
//| 获取最远的两笔持仓手数（用于斐波那契加仓）                       |
//+------------------------------------------------------------------+
void GetTwoExtremeLots(ENUM_POSITION_TYPE posType, double &lot1, double &lot2) {
    lot1 = 0;
    lot2 = 0;
    double price1 = 0, price2 = 0;

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

        double p   = PositionGetDouble(POSITION_PRICE_OPEN);
        double lot = PositionGetDouble(POSITION_VOLUME);

        if (posType == POSITION_TYPE_BUY) {
            // 做多：找价格最低的两笔
            if (price1 == 0 || p < price1) {
                price2 = price1; lot2 = lot1;
                price1 = p;      lot1 = lot;
            } else if (price2 == 0 || p < price2) {
                price2 = p;      lot2 = lot;
            }
        } else {
            // 做空：找价格最高的两笔
            if (price1 == 0 || p > price1) {
                price2 = price1; lot2 = lot1;
                price1 = p;      lot1 = lot;
            } else if (price2 == 0 || p > price2) {
                price2 = p;      lot2 = lot;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 获取最近一笔持仓的手数（用于马丁格尔加仓）                       |
//+------------------------------------------------------------------+
double GetLastLot(ENUM_POSITION_TYPE posType) {
    datetime latestTime = 0;
    double   latestLot  = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

        datetime t = (datetime)PositionGetInteger(POSITION_TIME);
        if (t > latestTime) {
            latestTime = t;
            latestLot  = PositionGetDouble(POSITION_VOLUME);
        }
    }
    return latestLot;
}

//+------------------------------------------------------------------+
//| 获取某方向所有持仓的总浮盈（含手续费）                           |
//+------------------------------------------------------------------+
double GetTotalProfit(ENUM_POSITION_TYPE posType) {
    double total = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;
        total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
    }
    return total;
}

//+------------------------------------------------------------------+
//| 统计某方向挂单数量                                               |
//+------------------------------------------------------------------+
int CountPendingOrders(ENUM_POSITION_TYPE dir) {
    string commentPrefix = (dir == POSITION_TYPE_BUY) ? PENDING_COMMENT_BUY : PENDING_COMMENT_SELL;
    int count = 0;
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if (OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
        string comment = OrderGetString(ORDER_COMMENT);
        if (StringFind(comment, commentPrefix) >= 0)
            count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| 获取某方向挂单 ticket（0=无挂单）                                |
//+------------------------------------------------------------------+
ulong GetPendingOrderTicket(ENUM_POSITION_TYPE dir) {
    string commentPrefix = (dir == POSITION_TYPE_BUY) ? PENDING_COMMENT_BUY : PENDING_COMMENT_SELL;
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if (OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
        string comment = OrderGetString(ORDER_COMMENT);
        if (StringFind(comment, commentPrefix) >= 0)
            return ticket;
    }
    return 0;
}

//+------------------------------------------------------------------+
//| 取消某方向所有挂单                                               |
//+------------------------------------------------------------------+
void CancelPendingOrders(ENUM_POSITION_TYPE dir) {
    string commentPrefix = (dir == POSITION_TYPE_BUY) ? PENDING_COMMENT_BUY : PENDING_COMMENT_SELL;
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if (OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
        string comment = OrderGetString(ORDER_COMMENT);
        if (StringFind(comment, commentPrefix) >= 0) {
            trade.OrderDelete(ticket);
            string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";
            WriteLog("PENDING CANCEL " + dirStr + " | Ticket: " + IntegerToString(ticket));
        }
    }
}

//+------------------------------------------------------------------+
//| 取消所有方向挂单                                                 |
//+------------------------------------------------------------------+
void CancelAllPendingOrders() {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0) continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if (OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
        string comment = OrderGetString(ORDER_COMMENT);
        if (StringFind(comment, PENDING_COMMENT_BUY) >= 0 ||
            StringFind(comment, PENDING_COMMENT_SELL) >= 0) {
            trade.OrderDelete(ticket);
            WriteLog("PENDING CANCEL ALL | Ticket: " + IntegerToString(ticket));
        }
    }
}

//+------------------------------------------------------------------+
//| 验证挂单价合法性                                                 |
//+------------------------------------------------------------------+
bool IsValidStopOrderPrice(ENUM_POSITION_TYPE dir, double stopPrice) {
    long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double minDist = stopLevel * symbolPoint;
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if (dir == POSITION_TYPE_BUY) {
        // BUY STOP: stopPrice 必须 > ask + StopsLevel
        return (stopPrice > ask + minDist);
    } else {
        // SELL STOP: stopPrice 必须 < bid - StopsLevel
        return (stopPrice < bid - minDist);
    }
}

//+------------------------------------------------------------------+
//| 按方向平掉所有持仓                                               |
//+------------------------------------------------------------------+
void ClosePositionsByType(ENUM_POSITION_TYPE posType) {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
            trade.PositionClose(ticket);
    }
    CancelPendingOrders(posType);
}

//+------------------------------------------------------------------+
//| 平掉所有持仓                                                     |
//+------------------------------------------------------------------+
void CloseAllPositions() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
        trade.PositionClose(ticket);
    }
    CancelAllPendingOrders();
}

//+------------------------------------------------------------------+
//| 回撤检查                                                         |
//+------------------------------------------------------------------+
bool CheckDrawdown() {
    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double maxLoss = accountEquityStart * MaxDrawdownPct / 100.0;
    return (accountEquityStart - equity) >= maxLoss;
}

//+------------------------------------------------------------------+
//| 日志记录                                                         |
//+------------------------------------------------------------------+
void WriteLog(string message) {
    bool isImportant =
        StringFind(message, "FAILED") >= 0 ||
        StringFind(message, "DRAWDOWN") >= 0 ||
        StringFind(message, "BREAKOUT") >= 0 ||
        StringFind(message, "MARTINGALE") >= 0 ||
        StringFind(message, "BASKET") >= 0 ||
        StringFind(message, "Single") >= 0 ||
        StringFind(message, "closed") >= 0 ||
        StringFind(message, "initialized") >= 0 ||
        StringFind(message, "deinitialized") >= 0 ||
        StringFind(message, "resumed") >= 0 ||
        StringFind(message, "WARNING") >= 0 ||
        StringFind(message, "recovery") >= 0 ||
        StringFind(message, "TREND") >= 0 ||
        StringFind(message, "PENDING") >= 0;

    if (!DebugMode && !isImportant) return;

    int handle = FileOpen(logFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
    if (handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        string ts = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
        FileWriteString(handle, ts + " | " + message + "\n");
        FileClose(handle);
    }
}
//+------------------------------------------------------------------+
//| 趋势对冲策略函数                                                 |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| 按方向统计趋势策略持仓数量                                       |
//+------------------------------------------------------------------+
int CountTrendPositions(ENUM_POSITION_TYPE posType) {
    int count = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != trendMagicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
            count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| 获取趋势策略极端入场价（做多=最高价，做空=最低价）               |
//+------------------------------------------------------------------+
double GetTrendExtremeEntryPrice(ENUM_POSITION_TYPE posType) {
    double result = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != trendMagicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

        double p = PositionGetDouble(POSITION_PRICE_OPEN);
        if (posType == POSITION_TYPE_BUY) {
            if (result == 0 || p > result) result = p;
        } else {
            if (result == 0 || p < result) result = p;
        }
    }
    return result;
}

//+------------------------------------------------------------------+
//| 按方向获取趋势策略总浮盈                                         |
//+------------------------------------------------------------------+
double GetTrendTotalProfit(ENUM_POSITION_TYPE posType) {
    double total = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != trendMagicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;
        total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
    }
    return total;
}

//+------------------------------------------------------------------+
//| 平掉所有趋势策略持仓                                             |
//+------------------------------------------------------------------+
void CloseTrendPositions() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != trendMagicNumber) continue;
        trade.PositionClose(ticket);
    }
    trendBuyPeakPrice = 0;
    trendSellPeakPrice = 0;
}

//+------------------------------------------------------------------+
//| 趋势策略：布林带上下轨突破入场（多空双向）                       |
//+------------------------------------------------------------------+
void CheckTrendBreakout(double ask, double bid, double atr) {
    // 读取布林带上下轨（使用已完成K线 bar[1]）
    double bbUpper[], bbLower[];
    ArraySetAsSeries(bbUpper, true);
    ArraySetAsSeries(bbLower, true);
    if (CopyBuffer(bbHandle, 1, 0, 2, bbUpper) <= 0 ||
        CopyBuffer(bbHandle, 2, 0, 2, bbLower) <= 0) return;
    double upperBand = bbUpper[1];
    double lowerBand = bbLower[1];

    // 做多突破：ask突破布林带上轨
    int trendBuyCount = CountTrendPositions(POSITION_TYPE_BUY);
    if (trendBuyCount == 0 && ask > upperBand) {
        double lot = NormalizeLot(CalcDynamicLot() * TrendLotMultiplier);
        if (CheckMargin(ORDER_TYPE_BUY, ask, lot)) {
            trade.SetExpertMagicNumber(trendMagicNumber);
            if (trade.Buy(lot, _Symbol, ask, 0, 0, "TREND BUY #1")) {
                trendBuyPeakPrice = bid;
                WriteLog("TREND BREAKOUT BUY #1 | Price: " + DoubleToString(ask, symbolDigits) +
                         " | BB Upper: " + DoubleToString(upperBand, symbolDigits) +
                         " | ATR: " + DoubleToString(atr, symbolDigits) +
                         " | Lot: " + DoubleToString(lot, 2));
            }
            trade.SetExpertMagicNumber(magicNumber);
        }
    }

    // 做空突破：bid跌破布林带下轨
    int trendSellCount = CountTrendPositions(POSITION_TYPE_SELL);
    if (trendSellCount == 0 && bid < lowerBand) {
        double lot = NormalizeLot(CalcDynamicLot() * TrendLotMultiplier);
        if (CheckMargin(ORDER_TYPE_SELL, bid, lot)) {
            trade.SetExpertMagicNumber(trendMagicNumber);
            if (trade.Sell(lot, _Symbol, bid, 0, 0, "TREND SELL #1")) {
                trendSellPeakPrice = bid;
                WriteLog("TREND BREAKOUT SELL #1 | Price: " + DoubleToString(bid, symbolDigits) +
                         " | BB Lower: " + DoubleToString(lowerBand, symbolDigits) +
                         " | ATR: " + DoubleToString(atr, symbolDigits) +
                         " | Lot: " + DoubleToString(lot, 2));
            }
            trade.SetExpertMagicNumber(magicNumber);
        }
    }
}

//+------------------------------------------------------------------+
//| 趋势策略：顺势加仓                                               |
//+------------------------------------------------------------------+
void CheckTrendAdd(ENUM_POSITION_TYPE dir, double price, double atr) {
    int count = CountTrendPositions(dir);
    if (count <= 0 || count > TrendMaxAdds) return;

    double extremePrice = GetTrendExtremeEntryPrice(dir);
    if (extremePrice <= 0) return;

    double addDistance = atr * TrendAddATRMultiplier;
    bool shouldAdd = false;

    if (dir == POSITION_TYPE_BUY)
        shouldAdd = (price >= extremePrice + addDistance);
    else
        shouldAdd = (price <= extremePrice - addDistance);

    if (!shouldAdd) return;

    double lot = NormalizeLot(CalcDynamicLot() * TrendLotMultiplier);
    ENUM_ORDER_TYPE orderType = (dir == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    if (!CheckMargin(orderType, price, lot)) return;

    string comment = ((dir == POSITION_TYPE_BUY) ? "TREND BUY #" : "TREND SELL #") +
                     IntegerToString(count + 1);
    string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";

    trade.SetExpertMagicNumber(trendMagicNumber);
    bool sent = false;
    if (dir == POSITION_TYPE_BUY)
        sent = trade.Buy(lot, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), 0, 0, comment);
    else
        sent = trade.Sell(lot, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), 0, 0, comment);

    if (sent) {
        WriteLog("TREND ADD " + dirStr + " #" + IntegerToString(count + 1) +
                 " | Price: " + DoubleToString(price, symbolDigits) +
                 " | Lot: " + DoubleToString(lot, 2) +
                 " | ATR x" + DoubleToString(TrendAddATRMultiplier, 1) +
                 " | Distance: " + DoubleToString(addDistance, symbolDigits) +
                 " | Total trend positions: " + IntegerToString(count + 1));
    }
    trade.SetExpertMagicNumber(magicNumber);
}

//+------------------------------------------------------------------+
//| 趋势策略：ATR追踪止盈                                            |
//+------------------------------------------------------------------+
void CheckTrendTrailStop(ENUM_POSITION_TYPE dir, double bid, double atr) {
    int count = CountTrendPositions(dir);
    if (count <= 0) {
        // 无持仓时重置峰/谷值
        if (dir == POSITION_TYPE_BUY) trendBuyPeakPrice = 0;
        else trendSellPeakPrice = 0;
        return;
    }

    double trailDistance = atr * TrendTrailATRMultiplier;
    string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";

    if (dir == POSITION_TYPE_BUY) {
        // 做多：跟踪bid最高值
        if (bid > trendBuyPeakPrice) trendBuyPeakPrice = bid;
        // bid从峰值回撤超过ATR × 倍数时平仓
        if (trendBuyPeakPrice > 0 && bid < trendBuyPeakPrice - trailDistance) {
            double profit = GetTrendTotalProfit(POSITION_TYPE_BUY);
            WriteLog("TREND TRAIL STOP " + dirStr + " | Bid: " + DoubleToString(bid, symbolDigits) +
                     " | Peak: " + DoubleToString(trendBuyPeakPrice, symbolDigits) +
                     " | Trail: " + DoubleToString(trailDistance, symbolDigits) +
                     " | Positions: " + IntegerToString(count) +
                     " | Profit: " + DoubleToString(profit, 2) + " USD");
            CloseTrendPositionsByDir(POSITION_TYPE_BUY);
            trendBuyPeakPrice = 0;
        }
    } else {
        // 做空：跟踪bid最低值
        if (trendSellPeakPrice == 0 || bid < trendSellPeakPrice) trendSellPeakPrice = bid;
        // bid从谷值反弹超过ATR × 倍数时平仓
        if (trendSellPeakPrice > 0 && bid > trendSellPeakPrice + trailDistance) {
            double profit = GetTrendTotalProfit(POSITION_TYPE_SELL);
            WriteLog("TREND TRAIL STOP " + dirStr + " | Bid: " + DoubleToString(bid, symbolDigits) +
                     " | Trough: " + DoubleToString(trendSellPeakPrice, symbolDigits) +
                     " | Trail: " + DoubleToString(trailDistance, symbolDigits) +
                     " | Positions: " + IntegerToString(count) +
                     " | Profit: " + DoubleToString(profit, 2) + " USD");
            CloseTrendPositionsByDir(POSITION_TYPE_SELL);
            trendSellPeakPrice = 0;
        }
    }
}

//+------------------------------------------------------------------+
//| 按方向平掉趋势策略持仓                                           |
//+------------------------------------------------------------------+
void CloseTrendPositionsByDir(ENUM_POSITION_TYPE posType) {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if (PositionGetInteger(POSITION_MAGIC) != trendMagicNumber) continue;
        if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
            trade.PositionClose(ticket);
    }
}
//+------------------------------------------------------------------+