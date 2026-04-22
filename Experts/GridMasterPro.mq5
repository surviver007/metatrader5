//+------------------------------------------------------------------+
//|                                              GridMasterPro.mq5   |
//|                                    Copyright 2026, wangxiaozhi.  |
//|                                           https://www.mql5.com   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, wangxiaozhi."
#property link      "https://www.mql5.com"
#property version   "4.0"
#property strict
#property description "连续两根阳线/阴线形态 + 动态间距加仓策略（固定点数止盈）"

#include <Trade\Trade.mqh>

sinput string _grp1 = "交易设置"; // ===== 交易设置 =====
input double         InitialLot       = 0.01;           // 固定初始手数（UseDynamicLot=false时生效）
input bool           UseDynamicLot    = true;           // 启用动态手数（按余额比例）
input double         RiskPercent      = 1.0;            // 动态手数：余额风险百分比
input int            FlatAddCount     = 5;              // 前N笔等量加仓（之后启用加仓模式）

sinput string _grp2 = "加仓模式"; // ===== 加仓模式 =====
enum ENUM_ADD_MODE {
    ADD_MARTIN   = 0,    // 马丁格尔（上一笔手数 × 倍数）
    ADD_FIBONACCI = 1    // 斐波那契（最远两笔手数之和）
};
input ENUM_ADD_MODE  AddMode          = ADD_MARTIN;     // 加仓手数模式
input double         MartinMultiplier = 1.5;            // 马丁格尔倍数（上一笔手数 × 此值）
input int            MaxPositions     = 50;             // 单方向最大持仓数
input double         ATRAddMultiplier = 1.0;            // 加仓间距基础ATR倍数
input double         ATRStepIncrement = 0.2;            // 加仓间距递增（每多一笔增加ATR倍数）
input int            CooldownBars     = 20;             // 回撤恢复后冷却K线数
input int            ATRPeriod        = 5;              // ATR周期
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

    string addModeStr = (AddMode == ADD_MARTIN) ?
                         "Martin x" + DoubleToString(MartinMultiplier, 1) : "Fibonacci";
    WriteLog("GridMaster Pro v4.0 initialized | Magic: " + IntegerToString(magicNumber) +
             " | Symbol: " + _Symbol + " | Strategy: 2-Candle Pattern + Dynamic Grid + Fixed TP" +
             " | AddMode: " + addModeStr + " after " + IntegerToString(FlatAddCount) + " flat" +
             " | MinBodyATR: " + DoubleToString(MinBodyATRRatio, 2) +
             " | BB: " + IntegerToString(BBPeriod) + " / " + DoubleToString(BBDeviation, 1) +
             " | ProfitTP: " + DoubleToString(ProfitPerPositionUSD, 2) + " USD/pos" +
             " | DynamicLot: " + (UseDynamicLot ? "ON " + DoubleToString(RiskPercent, 1) + "%" : "OFF"));

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EA 反初始化                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    if (atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    if (bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
    WriteLog("EA deinitialized. Reason: " + IntegerToString(reason) +
             " | Positions: " + IntegerToString(CountPositions(POSITION_TYPE_BUY) + CountPositions(POSITION_TYPE_SELL)));
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
    if (currentBarTime == lastBarTime) {
        // 非新K线，跳过入场但继续处理加仓
        if (atr > 0) {
            if (AllowBuy)  CheckMartingale(POSITION_TYPE_BUY, ask, atr);
            if (AllowSell) CheckMartingale(POSITION_TYPE_SELL, bid, atr);
        }
        return;
    }
    lastBarTime = currentBarTime;

    // --- 5. 读取最近两根已完成K线（bar[1] 和 bar[2]） ---
    double open1  = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
    double open2  = iOpen(_Symbol, PERIOD_CURRENT, 2);
    double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
    double body1  = MathAbs(close1 - open1);
    double body2  = MathAbs(close2 - open2);
    bool   isBull1 = (close1 > open1);   // bar[1] 阳线
    bool   isBear1 = (open1 > close1);   // bar[1] 阴线
    bool   isBull2 = (close2 > open2);   // bar[2] 阳线
    bool   isBear2 = (open2 > close2);   // bar[2] 阴线
    bool   body1Strong = (atr > 0 && body1 >= atr * MinBodyATRRatio);  // bar[1]实体够大
    bool   twoBull = (isBull1 && isBull2 && body1Strong);  // 连续两根阳线且最近一根实体够大
    bool   twoBear = (isBear1 && isBear2 && body1Strong);  // 连续两根阴线且最近一根实体够大

    // --- 6. K线形态入场 ---
    int buyCount  = CountPositions(POSITION_TYPE_BUY);
    int sellCount = CountPositions(POSITION_TYPE_SELL);

    // 做多：连续两根阳线，且当前无多头持仓
    if (!inCooldown && AllowBuy && twoBull && buyCount == 0) {
        double lot = CalcDynamicLot();
        if (CheckMargin(ORDER_TYPE_BUY, ask, lot)) {
            if (trade.Buy(lot, _Symbol, ask, 0, 0, "CANDLE BUY #1")) {
                WriteLog("CANDLE BUY #1 | Price: " + DoubleToString(ask, symbolDigits) +
                         " | Body1: " + DoubleToString(body1, symbolDigits) +
                         " Body2: " + DoubleToString(body2, symbolDigits) +
                         " | ATR: " + DoubleToString(atr, symbolDigits) +
                         " | Lot: " + DoubleToString(lot, 2));
            }
        }
    }

    // 做空：连续两根阴线，且当前无空头持仓
    if (!inCooldown && AllowSell && twoBear && sellCount == 0) {
        double lot = CalcDynamicLot();
        if (CheckMargin(ORDER_TYPE_SELL, bid, lot)) {
            if (trade.Sell(lot, _Symbol, bid, 0, 0, "CANDLE SELL #1")) {
                WriteLog("CANDLE SELL #1 | Price: " + DoubleToString(bid, symbolDigits) +
                         " | Body1: " + DoubleToString(body1, symbolDigits) +
                         " Body2: " + DoubleToString(body2, symbolDigits) +
                         " | ATR: " + DoubleToString(atr, symbolDigits) +
                         " | Lot: " + DoubleToString(lot, 2));
            }
        }
    }

    // --- 7. 马丁格尔加仓（动态间距） ---
    if (atr > 0) {
        if (AllowBuy)  CheckMartingale(POSITION_TYPE_BUY, ask, atr);
        if (AllowSell) CheckMartingale(POSITION_TYPE_SELL, bid, atr);
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
//| 马丁格尔加仓：亏损时在动态ATR距离处按倍数加仓                    |
//+------------------------------------------------------------------+
void CheckMartingale(ENUM_POSITION_TYPE dir, double currentPrice, double atr) {
    int count = CountPositions(dir);
    if (count <= 0 || count >= MaxPositions) return;

    // 只在整体亏损时加仓
    if (GetTotalProfit(dir) >= 0) return;

    // 获取最远入场价（做多取最低价，做空取最高价）
    double extremePrice = GetExtremeEntryPrice(dir);
    if (extremePrice <= 0) return;

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
        addModeStr = "MARTIN x" + DoubleToString(MartinMultiplier, 1);
    } else {
        // 斐波那契：最远两笔手数之和
        double lot1, lot2;
        GetTwoExtremeLots(dir, lot1, lot2);
        newLot = NormalizeLot(lot1 + lot2);
        addModeStr = "FIB";
    }

    ENUM_ORDER_TYPE orderType = (dir == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    if (!CheckMargin(orderType, currentPrice, newLot)) {
        if (DebugMode) WriteLog("Insufficient margin for " + addModeStr + " add");
        return;
    }

    string comment = ((dir == POSITION_TYPE_BUY) ? "BUY ADD #" : "SELL ADD #") +
                     IntegerToString(count + 1);

    bool sent = false;
    if (dir == POSITION_TYPE_BUY)
        sent = trade.Buy(newLot, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), 0, 0, comment);
    else
        sent = trade.Sell(newLot, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), 0, 0, comment);

    if (sent) {
        string dirStr = (dir == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        WriteLog(addModeStr + " ADD " + dirStr + " #" + IntegerToString(count + 1) +
                 " | Price: " + DoubleToString(currentPrice, symbolDigits) +
                 " | Lot: " + DoubleToString(newLot, 2) +
                 " | ATR x" + DoubleToString(currentMultiplier, 1) +
                 " | Distance: " + DoubleToString(addDistance, symbolDigits) +
                 " | Total positions: " + IntegerToString(count + 1));
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
        StringFind(message, "recovery") >= 0;

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
