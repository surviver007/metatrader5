//+------------------------------------------------------------------+
//|                                          BollingerPyramid.mq5     |
//|                                    Copyright 2026, wangxiaozhi.  |
//|                                           https://www.mql5.com   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, wangxiaozhi."
#property link      "https://www.mql5.com"
#property version   "1.0"
#property strict
#property description "布林带突破金字塔策略 — 突破上轨做多，每10点加仓，保护损+补单机制"

#include <Trade\Trade.mqh>

//--- 交易设置
input double         InitialLot       = 0.01;           // 固定初始手数（UseDynamicLot=false时生效）
input bool           UseDynamicLot    = false;          // 启用动态手数（按余额比例）
input double         RiskPercent      = 1.0;            // 动态手数：余额风险百分比

//--- 布林带设置
input int            BB_Period        = 20;             // 布林带周期
input double         BB_Deviation     = 2.0;            // 布林带标准差倍数
input ENUM_TIMEFRAMES BB_Timeframe    = PERIOD_CURRENT; // 布林带时间周期

//--- 金字塔设置
input int            MaxLevels        = 10;              // 最大金字塔层数（1-10）
input int            LevelSpacing     = 100;             // 每层间距（点数）
input int            TakeProfitPoints = 1000;            // 整体止盈点数（距初始入场价P0）
input int            StopLossPoints   = 1000;            // 整体止损点数（距P0反向）
input int            ProtectionPoints    = 30;              // 保护损缓冲点数（覆盖手续费）
input int            ProtectionDistance   = 50;              // 保护损触发距离（点数，价格距入场价此距离后设置保护止损）

//--- 风控管理
input double         MaxDrawdownPct   = 30.0;           // 最大回撤百分比
input int            MaxSpreadPoints  = 20;             // 最大点差（点）
input int            MagicBase        = 53179;          // 魔术号基数
input bool           DebugMode        = false;          // 调试模式

//--- 全局变量
CTrade   trade;
int      magicNumber;
string   logFile;
int      bbHandle;
int      symbolDigits;
double   symbolPoint;
datetime lastBarTime;
double   accountEquityStart;

//--- 周期状态
bool     cycleActive;
double   cycleP0;
int      cycleMaxLevel;

//--- 每层状态跟踪
bool     levelActive[10];
double   levelEntryPrice[10];
bool     levelSLHit[10];
ulong    levelTicket[10];
bool     levelBelowTarget[10];

//--- 全局变量名前缀（用于持久化）
string   gvPrefix;

//+------------------------------------------------------------------+
//| EA 初始化                                                        |
//+------------------------------------------------------------------+
int OnInit() {
   // 防冲突魔术号
   int symbolHash = 0;
   for(int i = 0; i < (int)StringLen(_Symbol); i++)
      symbolHash = (symbolHash * 31 + (int)StringGetCharacter(_Symbol, i)) & 0x7FFF;
   magicNumber = MagicBase + symbolHash + (int)Period();
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(DetectFillType());

   symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   symbolPoint  = _Point;

   accountEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   logFile   = "BollingerPyramid_" + _Symbol + "_" + IntegerToString(Period()) + ".log";
   gvPrefix  = "BP_" + _Symbol + "_" + IntegerToString(Period()) + "_";

   // 创建布林带指标句柄
   bbHandle = iBands(_Symbol, BB_Timeframe, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   if(bbHandle == INVALID_HANDLE) {
      WriteLog("FAILED to create Bollinger Bands indicator handle");
      return INIT_FAILED;
   }

   lastBarTime = 0;

   // 初始化层级状态
   cycleActive  = false;
   cycleP0      = 0;
   cycleMaxLevel = -1;
   ArrayInitialize(levelActive, false);
   ArrayInitialize(levelEntryPrice, 0);
   ArrayInitialize(levelSLHit, false);
   ArrayInitialize(levelTicket, 0);
   ArrayInitialize(levelBelowTarget, false);

   // 从持久化存储恢复周期状态
   LoadStateFromGlobalVars();

   WriteLog("BollingerPyramid v1.0 initialized | Magic: " + IntegerToString(magicNumber) +
            " | Symbol: " + _Symbol +
            " | BB(" + IntegerToString(BB_Period) + "," + DoubleToString(BB_Deviation, 1) + ")" +
            " | Levels: " + IntegerToString(MaxLevels) +
            " | Spacing: " + IntegerToString(LevelSpacing) + "pts" +
            " | TP: " + IntegerToString(TakeProfitPoints) + "pts | SL: " + IntegerToString(StopLossPoints) + "pts" +
            " | Protection: " + IntegerToString(ProtectionPoints) + "pts" +
            " | Cycle: " + (cycleActive ? "ACTIVE P0=" + DoubleToString(cycleP0, symbolDigits) : "IDLE"));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EA 反初始化                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
   WriteLog("EA deinitialized. Reason: " + IntegerToString(reason) +
            " | Positions: " + IntegerToString(CountAllPositions()));
}

//+------------------------------------------------------------------+
//| EA Tick 函数                                                     |
//+------------------------------------------------------------------+
void OnTick() {
   if(!IsMarketActive()) return;

   // --- 高水位更新 ---
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(currentEquity > accountEquityStart)
      accountEquityStart = currentEquity;

   // --- 回撤保护 ---
   if(CheckDrawdown()) {
      WriteLog("DRAWDOWN LIMIT REACHED — closing all positions");
      CloseAllPositions();
      EndCycle("DRAWDOWN");
      accountEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      return;
   }

   // --- 点差过滤 ---
   if((long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- 重建层级状态（从真实持仓） ---
   ReconstructLevelState();

   // --- 检测保护损被打掉的层 ---
   DetectSLHits();

   // ═══════════════════════════════════════════════════
   // 最高优先级：止盈/止损检查（周期活跃时）
   // ═══════════════════════════════════════════════════
   if(cycleActive && cycleP0 > 0) {
      // 止盈：bid >= P0 + TakeProfitPoints
      if(bid >= cycleP0 + TakeProfitPoints * symbolPoint) {
         double profit = GetAllProfit();
         CloseAllPositions();
         WriteLog("TAKE PROFIT | P0: " + DoubleToString(cycleP0, symbolDigits) +
                  " | Exit: " + DoubleToString(bid, symbolDigits) +
                  " | Points: +" + IntegerToString(TakeProfitPoints) +
                  " | Profit: " + DoubleToString(profit, 2));
         EndCycle("TP");
         return;
      }

      // 止损：bid <= P0 - StopLossPoints
      if(bid <= cycleP0 - StopLossPoints * symbolPoint) {
         double profit = GetAllProfit();
         CloseAllPositions();
         WriteLog("STOP LOSS | P0: " + DoubleToString(cycleP0, symbolDigits) +
                  " | Exit: " + DoubleToString(bid, symbolDigits) +
                  " | Points: -" + IntegerToString(StopLossPoints) +
                  " | Profit: " + DoubleToString(profit, 2));
         EndCycle("SL");
         return;
      }
   }

   // ═══════════════════════════════════════════════════
   // 无活跃周期：等待BB突破信号
   // ═══════════════════════════════════════════════════
   if(!cycleActive) {
      // 新K线检测（避免同根K线重复信号）
      datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(currentBarTime == lastBarTime) return;
      lastBarTime = currentBarTime;

      if(CheckBBBreakout()) {
         double lot = CalcDynamicLot();
         if(CheckMargin(ORDER_TYPE_BUY, ask, lot)) {
            if(trade.Buy(lot, _Symbol, ask, 0, 0, "BP_L0")) {
               cycleActive  = true;
               cycleP0      = ask;
               cycleMaxLevel = 0;
               levelActive[0]    = true;
               levelEntryPrice[0] = ask;
               levelTicket[0]    = (ulong)trade.ResultOrder();
               levelSLHit[0]     = false;

               SaveStateToGlobalVars();

               WriteLog("BREAKOUT BUY Level 0 | P0: " + DoubleToString(ask, symbolDigits) +
                        " | BB Upper breached" +
                        " | Lot: " + DoubleToString(lot, 2));
            } else {
               WriteLog("FAILED BREAKOUT BUY | Error: " + IntegerToString(trade.ResultRetcode()));
            }
         }
      }
      return;
   }

   // ═══════════════════════════════════════════════════
   // 周期活跃：管理金字塔
   // ═══════════════════════════════════════════════════

   // 1. 补单（保护损被打掉后价格回来时重新入场）
   CheckReentry();

   // 2. 加仓（价格达到下一层级时）
   CheckAddLevel();

   // 3. 更新保护损（确保所有非最新层有保护损）
   UpdateProtectiveSL();

   // 4. 保存状态
   SaveStateToGlobalVars();
}

//+------------------------------------------------------------------+
//| 检测布林带上轨突破（使用完成K线bar[1]）                           |
//+------------------------------------------------------------------+
bool CheckBBBreakout() {
   double bbUpper[];
   ArraySetAsSeries(bbUpper, true);
   if(CopyBuffer(bbHandle, 1, 0, 2, bbUpper) < 2) return false;  // buffer 1 = 上轨

   // 使用完成K线（bar[1]）的收盘价 vs bar[1]的布林带上轨
   double close1 = iClose(_Symbol, BB_Timeframe, 1);
   if(close1 <= 0) return false;

   if(close1 > bbUpper[1]) {
      WriteLog("BB BREAKOUT signal | Close: " + DoubleToString(close1, symbolDigits) +
               " | UpperBand: " + DoubleToString(bbUpper[1], symbolDigits) +
               " | Diff: " + DoubleToString((close1 - bbUpper[1]) / symbolPoint, 1) + "pts");
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| 从持仓列表重建层级状态                                           |
//+------------------------------------------------------------------+
void ReconstructLevelState() {
   // 先保存上一次的活跃状态（用于DetectSLHits对比）
   bool prevActive[10];
   for(int i = 0; i < 10; i++) prevActive[i] = levelActive[i];

   // 重置所有层级状态
   for(int i = 0; i < 10; i++) {
      levelActive[i]     = false;
      levelEntryPrice[i] = 0;
      levelTicket[i]     = 0;
   }

   cycleMaxLevel = -1;

   // 扫描所有持仓，按注释匹配层级
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      string comment = PositionGetString(POSITION_COMMENT);
      int level = ParseCommentLevel(comment);
      if(level >= 0 && level < MaxLevels) {
         levelActive[level]     = true;
         levelEntryPrice[level] = PositionGetDouble(POSITION_PRICE_OPEN);
         levelTicket[level]     = ticket;
         if(level > cycleMaxLevel)
            cycleMaxLevel = level;
      }
   }

   // 如果没有任何持仓且没有待补单的层级，说明周期已结束
   if(cycleActive && cycleMaxLevel < 0) {
      bool hasSLHit = false;
      for(int i = 0; i < MaxLevels; i++) {
         if(levelSLHit[i]) { hasSLHit = true; break; }
      }
      if(!hasSLHit) {
         WriteLog("Cycle has no positions and no pending re-entries — auto-ending cycle");
         EndCycle("AUTO");
      }
   }
}

//+------------------------------------------------------------------+
//| 检测保护损被打掉的层级                                           |
//+------------------------------------------------------------------+
void DetectSLHits() {
   if(!cycleActive) return;

   // 检查每个层级：全局变量标记为活跃但实际无持仓 → 被SL打掉
   for(int i = 0; i < MaxLevels; i++) {
      // 跳过已经是SL标记或本来就是空的层级
      if(levelSLHit[i]) continue;
      if(levelActive[i]) continue;  // 当前有持仓，正常

      // 检查全局变量中是否记录了该层级曾经开过仓
      string gvName = gvPrefix + "Active_L" + IntegerToString(i);
      if(GlobalVariableCheck(gvName) && GlobalVariableGet(gvName) > 0.5) {
         // 该层级曾经有仓位，但现在没有了 → 保护损被打掉
         levelSLHit[i] = true;
         levelBelowTarget[i] = false;  // 保护损刚打掉，价格仍在目标上方

         // 从全局变量获取该层的入场价
         string gvEntry = gvPrefix + "Entry_L" + IntegerToString(i);
         if(GlobalVariableCheck(gvEntry))
            levelEntryPrice[i] = GlobalVariableGet(gvEntry);

         WriteLog("PROTECTION SL HIT | Level: " + IntegerToString(i) +
                  " | Entry was: " + DoubleToString(levelEntryPrice[i], symbolDigits));

         SaveSLHitState();
      }
   }
}

//+------------------------------------------------------------------+
//| 补单：保护损被打掉后，价格回来时重新入场                         |
//+------------------------------------------------------------------+
void CheckReentry() {
   if(!cycleActive) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = 0; i < MaxLevels; i++) {
      if(!levelSLHit[i]) continue;

      // 该层的目标入场价
      double targetPrice = cycleP0 + i * LevelSpacing * symbolPoint;

      // 追踪价格是否已回落到目标以下
      if(bid < targetPrice) {
         if(!levelBelowTarget[i]) {
            levelBelowTarget[i] = true;
            SaveStateToGlobalVars();
         }
         continue;
      }

      // 只有价格曾跌破目标并回升时才补单（防止保护损刚打掉就立即高价补单）
      if(!levelBelowTarget[i]) continue;

      // 价格曾跌破目标，现在回升到目标上方，执行补单
      double lot = CalcDynamicLot();
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(CheckMargin(ORDER_TYPE_BUY, ask, lot)) {
         string comment = "BP_L" + IntegerToString(i);
         if(trade.Buy(lot, _Symbol, ask, 0, 0, comment)) {
            levelSLHit[i]       = false;
            levelBelowTarget[i] = false;
            levelActive[i]      = true;
            levelEntryPrice[i]  = ask;
            levelTicket[i]      = (ulong)trade.ResultOrder();
            if(i > cycleMaxLevel) cycleMaxLevel = i;

            WriteLog("RE-ENTRY Level " + IntegerToString(i) +
                     " | Price: " + DoubleToString(ask, symbolDigits) +
                     " | Target was: " + DoubleToString(targetPrice, symbolDigits) +
                     " | Lot: " + DoubleToString(lot, 2));

            SaveStateToGlobalVars();

            // 补单后立即更新保护损
            UpdateProtectiveSL();
            return;  // 每根K线只补一单，避免过度操作
         } else {
            WriteLog("FAILED RE-ENTRY Level " + IntegerToString(i) +
                     " | Error: " + IntegerToString(trade.ResultRetcode()));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 加仓：价格达到下一层级时开新仓                                   |
//+------------------------------------------------------------------+
void CheckAddLevel() {
   if(!cycleActive) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // 寻找下一个需要开仓的层级
   for(int i = 0; i < MaxLevels; i++) {
      if(levelActive[i]) continue;      // 已有持仓
      if(levelSLHit[i]) continue;       // 被打掉等待补单
      if(i == 0) continue;              // Level 0 是初始入场，不是加仓

      // 检查前置层级是否有持仓（金字塔必须逐层构建）
      if(i > 0 && !levelActive[i - 1] && !levelSLHit[i - 1]) continue;

      double targetPrice = cycleP0 + i * LevelSpacing * symbolPoint;

      if(bid >= targetPrice) {
         OpenPositionAtLevel(i);
         return;  // 每tick只加一层
      }

      break;  // 还没到这一层，后面的更不用看
   }
}

//+------------------------------------------------------------------+
//| 在指定层级开仓                                                   |
//+------------------------------------------------------------------+
void OpenPositionAtLevel(int level) {
   double lot = CalcDynamicLot();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(!CheckMargin(ORDER_TYPE_BUY, ask, lot)) {
      WriteLog("WARNING Insufficient margin for Level " + IntegerToString(level));
      return;
   }

   string comment = "BP_L" + IntegerToString(level);
   if(trade.Buy(lot, _Symbol, ask, 0, 0, comment)) {
      levelActive[level]     = true;
      levelEntryPrice[level] = ask;
      levelTicket[level]     = (ulong)trade.ResultOrder();
      levelSLHit[level]      = false;
      if(level > cycleMaxLevel) cycleMaxLevel = level;

      WriteLog("ADD Level " + IntegerToString(level) +
               " | Price: " + DoubleToString(ask, symbolDigits) +
               " | Target: " + DoubleToString(cycleP0 + level * LevelSpacing * symbolPoint, symbolDigits) +
               " | Lot: " + DoubleToString(lot, 2) +
               " | Total active: " + IntegerToString(CountActiveLevels()));

      SaveStateToGlobalVars();

      // 加仓后立即为所有更早的仓位设置保护损
      UpdateProtectiveSL();
   } else {
      WriteLog("FAILED ADD Level " + IntegerToString(level) +
               " | Error: " + IntegerToString(trade.ResultRetcode()));
   }
}

//+------------------------------------------------------------------+
//| 更新保护损：为所有活跃层设置保护性止损                           |
//+------------------------------------------------------------------+
void UpdateProtectiveSL() {
   if(!cycleActive) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = 0; i < MaxLevels; i++) {
      if(!levelActive[i]) continue;

      ulong ticket = levelTicket[i];
      if(ticket == 0) continue;

      // 验证ticket仍然有效
      if(!PositionSelectByTicket(ticket)) continue;

      // 价格必须距离入场价超过 ProtectionDistance 点才设置保护损（避免刚补单就被打掉）
      if(bid < levelEntryPrice[i] + ProtectionDistance * symbolPoint) continue;

      // 保护损价格 = 入场价 + ProtectionPoints 点（覆盖手续费的微利）
      double slPrice = NormalizeDouble(levelEntryPrice[i] + ProtectionPoints * symbolPoint, symbolDigits);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      // 只在SL未设置或不正确时修改（避免频繁修改）
      if(MathAbs(currentSL - slPrice) > symbolPoint * 0.5) {
         if(trade.PositionModify(ticket, slPrice, currentTP)) {
            if(DebugMode) {
               WriteLog("Protection SL set | Level " + IntegerToString(i) +
                        " | Entry: " + DoubleToString(levelEntryPrice[i], symbolDigits) +
                        " | SL: " + DoubleToString(slPrice, symbolDigits) +
                        " | Buffer: " + IntegerToString(ProtectionPoints) + "pts");
            }
         } else {
            WriteLog("FAILED to set protection SL | Level " + IntegerToString(i) +
                     " | Error: " + IntegerToString(trade.ResultRetcode()));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 结束周期：清除所有状态                                           |
//+------------------------------------------------------------------+
void EndCycle(string reason) {
   WriteLog("CYCLE END (" + reason + ") | P0 was: " + DoubleToString(cycleP0, symbolDigits));

   // 清除所有层级状态
   for(int i = 0; i < 10; i++) {
      levelActive[i]     = false;
      levelEntryPrice[i] = 0;
      levelSLHit[i]      = false;
      levelTicket[i]     = 0;
      levelBelowTarget[i] = false;
   }

   cycleActive   = false;
   cycleP0       = 0;
   cycleMaxLevel = -1;

   // 清除持久化全局变量
   ClearAllGlobalVars();
}

//+------------------------------------------------------------------+
//| 解析仓位注释中的层级编号                                         |
//+------------------------------------------------------------------+
int ParseCommentLevel(string comment) {
   // 期望格式: "BP_L0" ~ "BP_L9"
   int pos = StringFind(comment, "BP_L");
   if(pos < 0) return -1;

   string levelStr = StringSubstr(comment, pos + 4, 1);
   int level = (int)StringToInteger(levelStr);
   if(level >= 0 && level < 10) return level;
   return -1;
}

//+------------------------------------------------------------------+
//| 统计活跃层级数量                                                 |
//+------------------------------------------------------------------+
int CountActiveLevels() {
   int count = 0;
   for(int i = 0; i < MaxLevels; i++)
      if(levelActive[i]) count++;
   return count;
}

//+------------------------------------------------------------------+
//| 统计所有持仓数量（本EA、本品种）                                 |
//+------------------------------------------------------------------+
int CountAllPositions() {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| 获取所有持仓总盈亏（含手续费）                                   |
//+------------------------------------------------------------------+
double GetAllProfit() {
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return total;
}

//+------------------------------------------------------------------+
//| 平掉所有持仓                                                     |
//+------------------------------------------------------------------+
void CloseAllPositions() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| 保存周期状态到全局变量（持久化，终端重启可恢复）                 |
//+------------------------------------------------------------------+
void SaveStateToGlobalVars() {
   GlobalVariableSet(gvPrefix + "CycleActive", cycleActive ? 1.0 : 0.0);
   GlobalVariableSet(gvPrefix + "CycleP0", cycleP0);
   GlobalVariableSet(gvPrefix + "MaxLevel", cycleMaxLevel);

   for(int i = 0; i < MaxLevels; i++) {
      GlobalVariableSet(gvPrefix + "Active_L" + IntegerToString(i), levelActive[i] ? 1.0 : 0.0);
      GlobalVariableSet(gvPrefix + "Entry_L" + IntegerToString(i), levelEntryPrice[i]);
      GlobalVariableSet(gvPrefix + "SLHit_L" + IntegerToString(i), levelSLHit[i] ? 1.0 : 0.0);
      GlobalVariableSet(gvPrefix + "Below_L" + IntegerToString(i), levelBelowTarget[i] ? 1.0 : 0.0);
   }
}

//+------------------------------------------------------------------+
//| 保存保护损标记状态                                               |
//+------------------------------------------------------------------+
void SaveSLHitState() {
   for(int i = 0; i < MaxLevels; i++) {
      GlobalVariableSet(gvPrefix + "SLHit_L" + IntegerToString(i), levelSLHit[i] ? 1.0 : 0.0);
   }
}

//+------------------------------------------------------------------+
//| 从全局变量恢复周期状态                                           |
//+------------------------------------------------------------------+
void LoadStateFromGlobalVars() {
   string nameActive = gvPrefix + "CycleActive";
   if(!GlobalVariableCheck(nameActive)) return;

   cycleActive = (GlobalVariableGet(nameActive) > 0.5);
   if(!cycleActive) return;

   cycleP0 = GlobalVariableGet(gvPrefix + "CycleP0");

   // 加载SL标记和回落追踪
   for(int i = 0; i < MaxLevels; i++) {
      string gvSLHit = gvPrefix + "SLHit_L" + IntegerToString(i);
      if(GlobalVariableCheck(gvSLHit))
         levelSLHit[i] = (GlobalVariableGet(gvSLHit) > 0.5);
      string gvBelow = gvPrefix + "Below_L" + IntegerToString(i);
      if(GlobalVariableCheck(gvBelow))
         levelBelowTarget[i] = (GlobalVariableGet(gvBelow) > 0.5);
   }

   WriteLog("Cycle state restored from persistence | P0: " + DoubleToString(cycleP0, symbolDigits));
}

//+------------------------------------------------------------------+
//| 清除所有全局变量                                                 |
//+------------------------------------------------------------------+
void ClearAllGlobalVars() {
   GlobalVariableDel(gvPrefix + "CycleActive");
   GlobalVariableDel(gvPrefix + "CycleP0");
   GlobalVariableDel(gvPrefix + "MaxLevel");

   for(int i = 0; i < MaxLevels; i++) {
      GlobalVariableDel(gvPrefix + "Active_L" + IntegerToString(i));
      GlobalVariableDel(gvPrefix + "Entry_L" + IntegerToString(i));
      GlobalVariableDel(gvPrefix + "SLHit_L" + IntegerToString(i));
      GlobalVariableDel(gvPrefix + "Below_L" + IntegerToString(i));
   }
}

//+------------------------------------------------------------------+
//| 检测经纪商支持的成交类型                                         |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillType() {
   long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((fillMode & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| 检查市场是否活跃且允许交易                                       |
//+------------------------------------------------------------------+
bool IsMarketActive() {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;

   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode != SYMBOL_TRADE_MODE_FULL) return false;

   // 周末检查（加密货币等品种跳过）
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) {
      string sym = _Symbol;
      if(StringFind(sym, "BTC") < 0 && StringFind(sym, "ETH") < 0 &&
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
   if(!UseDynamicLot) return NormalizeLot(InitialLot);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double marginForOneLot;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0,
                       SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginForOneLot))
      return NormalizeLot(InitialLot);

   if(marginForOneLot <= 0) return NormalizeLot(InitialLot);

   double lot = balance * RiskPercent / 100.0 / marginForOneLot;
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| 保证金检查                                                       |
//+------------------------------------------------------------------+
bool CheckMargin(ENUM_ORDER_TYPE type, double price, double lot) {
   double margin;
   if(!OrderCalcMargin(type, _Symbol, lot, price, margin)) return false;
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return margin <= freeMargin * 0.95;
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
      StringFind(message, "TAKE PROFIT") >= 0 ||
      StringFind(message, "STOP LOSS") >= 0 ||
      StringFind(message, "PROTECTION SL") >= 0 ||
      StringFind(message, "RE-ENTRY") >= 0 ||
      StringFind(message, "ADD Level") >= 0 ||
      StringFind(message, "CYCLE END") >= 0 ||
      StringFind(message, "initialized") >= 0 ||
      StringFind(message, "deinitialized") >= 0 ||
      StringFind(message, "restored") >= 0 ||
      StringFind(message, "WARNING") >= 0 ||
      StringFind(message, "closed") >= 0 ||
      StringFind(message, "auto-ending") >= 0;

   if(!DebugMode && !isImportant) return;

   int handle = FileOpen(logFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      string ts = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
      FileWriteString(handle, ts + " | " + message + "\n");
      FileClose(handle);
   }
}
//+------------------------------------------------------------------+
