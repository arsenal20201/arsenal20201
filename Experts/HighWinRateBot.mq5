//+------------------------------------------------------------------+
//|                                              HighWinRateBot.mq5   |
//|          High Win-Rate Trend-Pullback EA for MetaTrader 5  (v2)   |
//|                                                                  |
//|  v2 reworks the entry to cut chop-driven false trades and        |
//|  premature stop-outs: ADX/DMI trend-strength gate, slow-EMA      |
//|  slope filter, real pullback-to-value (price tags the fast-EMA   |
//|  zone + RSI dips into value), "not overextended" guard, a        |
//|  confirmation candle, structure-based (swing) stops, and a       |
//|  consecutive-loss cooldown. Risk: %-equity sizing, daily loss    |
//|  limit, profit lock, max positions/trades, spread + session      |
//|  filters, scale-out partial TP, break-even, ATR trailing.        |
//|                                                                  |
//|  NOTE: Educational tool. Forward-test on DEMO before going live. |
//+------------------------------------------------------------------+
#property copyright "HighWinRateBot"
#property link      "https://github.com/arsenal20201/arsenal20201"
#property version   "2.00"
#property strict

#include <HWRBot/SignalEngine.mqh>
#include <HWRBot/RiskManager.mqh>
#include <HWRBot/TradeManager.mqh>

//--- Strategy core ---------------------------------------------------
input group "=== Strategy ==="
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_M15;   // Working timeframe
input int    InpEmaFast                = 50;           // Fast EMA (swing)
input int    InpEmaSlow                = 200;          // Slow EMA (trend filter)
input int    InpRsiPeriod              = 14;           // RSI period
input double InpRsiBuyZone             = 45.0;         // RSI pullback zone for longs
input double InpRsiSellZone            = 55.0;         // RSI pullback zone for shorts
input int    InpAtrPeriod              = 14;           // ATR period

//--- Trend quality filters ------------------------------------------
input group "=== Trend Quality ==="
input bool   InpUseHtfFilter           = true;         // Require higher-TF trend agreement
input ENUM_TIMEFRAMES InpHtfTimeframe  = PERIOD_H1;    // Higher timeframe
input int    InpHtfEmaPeriod           = 200;          // Higher-TF EMA period
input bool   InpUseAdx                 = true;         // Require ADX trend strength
input int    InpAdxPeriod              = 14;           // ADX / DMI period
input double InpAdxMin                 = 22.0;         // Min ADX to trade
input bool   InpUseSlope               = true;         // Require slow-EMA slope agreement
input int    InpSlopeLen               = 5;            // Slope lookback (bars)

//--- Pullback & confirmation ----------------------------------------
input group "=== Pullback & Confirmation ==="
input int    InpPullLookback           = 6;            // Pullback lookback (bars)
input double InpPullTolAtr             = 0.5;          // EMA-tag tolerance (ATR x)
input bool   InpConfirmBar             = true;         // Require confirmation candle vs EMA
input double InpMaxExtAtr              = 2.0;          // Max distance from fast EMA (ATR x)

//--- Stops & targets ------------------------------------------------
input group "=== Stops & Targets ==="
input bool   InpUseSwingStop           = true;         // Structure (swing) stop
input int    InpSwingLook              = 10;           // Swing lookback (bars)
input double InpStopBufAtr             = 0.3;          // Stop buffer beyond swing (ATR x)
input double InpAtrSlMult              = 1.2;          // Min stop = ATR x
input double InpMaxStopAtr             = 3.5;          // Max stop = ATR x
input double InpRewardRiskRatio        = 1.8;          // Take-profit R:R
input int    InpMinAtrPoints           = 0;            // Min ATR in points to trade (0=off)

//--- Risk management -------------------------------------------------
input group "=== Risk Management ==="
input double InpRiskPercent            = 1.0;          // Risk % of balance per trade
input double InpMaxDailyLossPct        = 4.0;          // Stop trading after daily loss %
input double InpDailyProfitTargetPct   = 6.0;          // Stop trading after daily profit % (0=off)
input int    InpMaxPositions           = 1;            // Max concurrent positions
input int    InpMaxTradesPerDay        = 5;            // Max new trades per day (0=unlimited)
input int    InpMaxSpreadPoints        = 30;           // Max allowed spread (points, 0=off)
input int    InpMaxConsLoss            = 3;            // Cooldown after N losses (0=off)

//--- Session filter --------------------------------------------------
input group "=== Session Filter (server time) ==="
input bool   InpUseSession             = false;        // Restrict trading hours
input int    InpSessionStartHour       = 7;            // Session start hour
input int    InpSessionEndHour         = 20;           // Session end hour

//--- Trade management ------------------------------------------------
input group "=== Trade Management ==="
input bool   InpUsePartialTP           = true;         // Scale out partial at first target
input double InpPartialTriggerR        = 1.0;          // Take partial after this many R
input double InpPartialPercent         = 50.0;         // % of position to close at partial
input bool   InpUseBreakEven           = true;         // Enable break-even
input double InpBreakEvenTriggerR      = 1.0;          // Move to BE after this many R profit
input double InpBreakEvenLockPoints    = 20;           // Points locked beyond entry at BE
input bool   InpUseTrailing            = true;         // Enable ATR trailing stop
input double InpTrailAtrMult           = 2.0;          // Trailing distance = ATR x
input double InpTrailStartR            = 1.5;          // Start trailing after this many R

//--- General ---------------------------------------------------------
input group "=== General ==="
input long   InpMagicNumber            = 20240617;     // Magic number
input int    InpSlippagePoints         = 20;           // Max slippage (points)
input bool   InpOnePerBar              = true;         // Only one entry per bar

//--- Globals ---------------------------------------------------------
CSignalEngine  g_signal;
CRiskManager   g_risk;
CTradeManager  g_trade;
datetime       g_lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpEmaFast>=InpEmaSlow)
     { Print("Init error: Fast EMA must be smaller than Slow EMA"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskPercent<=0.0 || InpRiskPercent>20.0)
     { Print("Init error: Risk percent should be in (0, 20]"); return INIT_PARAMETERS_INCORRECT; }
   if(InpAtrSlMult<=0.0 || InpRewardRiskRatio<=0.0 || InpMaxStopAtr<InpAtrSlMult)
     { Print("Init error: check ATR SL / max-stop / R:R values"); return INIT_PARAMETERS_INCORRECT; }
   if(InpUsePartialTP && (InpPartialPercent<=0.0 || InpPartialPercent>=100.0))
     { Print("Init error: Partial percent must be between 0 and 100"); return INIT_PARAMETERS_INCORRECT; }

   if(!g_signal.Init(_Symbol,InpTimeframe,InpEmaFast,InpEmaSlow,
                     InpRsiPeriod,InpRsiBuyZone,InpRsiSellZone,InpAtrPeriod,
                     InpUseHtfFilter,InpHtfTimeframe,InpHtfEmaPeriod,
                     InpUseAdx,InpAdxPeriod,InpAdxMin,
                     InpUseSlope,InpSlopeLen,
                     InpPullLookback,InpPullTolAtr,
                     InpConfirmBar,InpMaxExtAtr,
                     InpUseSwingStop,InpSwingLook,InpStopBufAtr,
                     InpAtrSlMult,InpMaxStopAtr))
      return INIT_FAILED;

   g_risk.Init(_Symbol,InpMagicNumber,InpRiskPercent,InpMaxDailyLossPct,
               InpDailyProfitTargetPct,InpMaxPositions,InpMaxTradesPerDay,
               InpMaxSpreadPoints,InpUseSession,InpSessionStartHour,InpSessionEndHour,
               InpMaxConsLoss);

   g_trade.Init(_Symbol,InpMagicNumber,InpSlippagePoints,
                InpUsePartialTP,InpPartialTriggerR,InpPartialPercent,
                InpUseBreakEven,InpBreakEvenTriggerR,InpBreakEvenLockPoints,
                InpUseTrailing,InpTrailAtrMult,InpTrailStartR);

   Print("HighWinRateBot v2.00 initialized on ",_Symbol," ",EnumToString(InpTimeframe));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { g_signal.Deinit(); }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t=iTime(_Symbol,InpTimeframe,0);
   if(t!=g_lastBarTime){ g_lastBarTime=t; return true; }
   return false;
  }

//+------------------------------------------------------------------+
//| Feed closed-trade results into the consecutive-loss cooldown     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(trans.deal,DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal,DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
   g_risk.RegisterTradeClosed(profit);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- manage live trades on every tick (partial/break-even/trailing)
   double atr=g_signal.GetATR(1);
   g_trade.ManageOpenPositions(atr);

   //--- entries evaluated once per closed bar
   bool newBar=IsNewBar();
   if(InpOnePerBar && !newBar)
      return;

   string reason;
   if(!g_risk.CanOpenNewTrade(reason))
      return;

   ENUM_SIGNAL sig=g_signal.CheckSignal();
   if(sig==SIGNAL_NONE)
      return;
   if(atr<=0.0)
      return;
   if(InpMinAtrPoints>0 && (atr/_Point)<InpMinAtrPoints)
      return;

   //--- entry price and structure-based stop
   double entry = (sig==SIGNAL_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                                    : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl=g_signal.GetStopPrice((int)sig,entry,atr);
   if(sl<=0.0)
      return;

   double slDist=MathAbs(entry-sl);
   if(slDist<=0.0)
      return;
   double tp = (sig==SIGNAL_BUY) ? entry+slDist*InpRewardRiskRatio
                                 : entry-slDist*InpRewardRiskRatio;

   double lots=g_risk.CalcLotSize(slDist);
   if(lots<=0.0)
     { Print("Trade skipped: computed lot size is zero"); return; }

   string comment=StringFormat("HWRBot %s R:R %.1f",
                               (sig==SIGNAL_BUY?"LONG":"SHORT"),InpRewardRiskRatio);

   if(g_trade.OpenTrade((int)sig,lots,sl,tp,comment))
     {
      g_risk.RegisterTradeOpened();
      PrintFormat("Opened %s lots=%.2f entry=%.5f SL=%.5f TP=%.5f Rdist=%.5f ATR=%.5f dailyPnL=%.2f%%",
                  (sig==SIGNAL_BUY?"BUY":"SELL"),lots,entry,sl,tp,slDist,atr,g_risk.DailyProfitPct());
     }
  }
//+------------------------------------------------------------------+
