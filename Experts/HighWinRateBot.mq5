//+------------------------------------------------------------------+
//|                                              HighWinRateBot.mq5   |
//|             High Win-Rate Trend-Pullback EA for MetaTrader 5      |
//|                                                                  |
//|  Strategy:  Trade only WITH the higher-trend, enter on RSI       |
//|             pullbacks into value, confirmed by a momentum turn.  |
//|             ATR-based stops/targets keep risk:reward consistent. |
//|                                                                  |
//|  Risk mgmt: % equity risk per trade (auto lot sizing), daily     |
//|             loss limit, daily profit lock, max positions, max    |
//|             trades/day, spread filter, session filter,           |
//|             break-even + ATR trailing stop.                      |
//|                                                                  |
//|  NOTE: Educational tool. Always forward-test on a DEMO account   |
//|        before risking real capital. Past performance does not    |
//|        guarantee future results.                                 |
//+------------------------------------------------------------------+
#property copyright "HighWinRateBot"
#property link      "https://github.com/arsenal20201/arsenal20201"
#property version   "1.00"
#property strict

#include <HWRBot/SignalEngine.mqh>
#include <HWRBot/RiskManager.mqh>
#include <HWRBot/TradeManager.mqh>

//--- Strategy inputs -------------------------------------------------
input group "=== Strategy ==="
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_M15;   // Working timeframe
input int    InpEmaFast                = 50;           // Fast EMA (swing)
input int    InpEmaSlow                = 200;          // Slow EMA (trend filter)
input int    InpRsiPeriod              = 14;           // RSI period
input double InpRsiBuyZone             = 40.0;         // RSI pullback zone for longs
input double InpRsiSellZone            = 60.0;         // RSI pullback zone for shorts
input int    InpAtrPeriod              = 14;           // ATR period

//--- Stop / target ---------------------------------------------------
input group "=== Stops & Targets ==="
input double InpAtrSlMult              = 1.5;          // Stop-loss = ATR x this
input double InpRewardRiskRatio        = 1.5;          // Take-profit = R:R x risk

//--- Risk management -------------------------------------------------
input group "=== Risk Management ==="
input double InpRiskPercent            = 1.0;          // Risk % of balance per trade
input double InpMaxDailyLossPct        = 4.0;          // Stop trading after daily loss %
input double InpDailyProfitTargetPct   = 6.0;          // Stop trading after daily profit % (0=off)
input int    InpMaxPositions           = 1;            // Max concurrent positions
input int    InpMaxTradesPerDay        = 5;            // Max new trades per day (0=unlimited)
input int    InpMaxSpreadPoints        = 30;           // Max allowed spread (points, 0=off)

//--- Session filter --------------------------------------------------
input group "=== Session Filter (server time) ==="
input bool   InpUseSession             = false;        // Restrict trading hours
input int    InpSessionStartHour       = 7;            // Session start hour
input int    InpSessionEndHour         = 20;           // Session end hour

//--- Trade management ------------------------------------------------
input group "=== Trade Management ==="
input bool   InpUseBreakEven           = true;         // Enable break-even
input double InpBreakEvenTriggerR      = 1.0;          // Move to BE after this many R profit
input double InpBreakEvenLockPoints    = 20;           // Points locked beyond entry at BE
input bool   InpUseTrailing            = true;         // Enable ATR trailing stop
input double InpTrailAtrMult           = 2.0;          // Trailing distance = ATR x this
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
   //--- basic input sanity checks
   if(InpEmaFast>=InpEmaSlow)
     {
      Print("Init error: Fast EMA period must be smaller than Slow EMA period");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPercent<=0.0 || InpRiskPercent>20.0)
     {
      Print("Init error: Risk percent should be in (0, 20]");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpAtrSlMult<=0.0 || InpRewardRiskRatio<=0.0)
     {
      Print("Init error: ATR SL multiple and R:R ratio must be positive");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(!g_signal.Init(_Symbol,InpTimeframe,InpEmaFast,InpEmaSlow,
                     InpRsiPeriod,InpRsiBuyZone,InpRsiSellZone,InpAtrPeriod))
      return INIT_FAILED;

   g_risk.Init(_Symbol,InpMagicNumber,InpRiskPercent,InpMaxDailyLossPct,
               InpDailyProfitTargetPct,InpMaxPositions,InpMaxTradesPerDay,
               InpMaxSpreadPoints,InpUseSession,InpSessionStartHour,InpSessionEndHour);

   g_trade.Init(_Symbol,InpMagicNumber,InpSlippagePoints,
                InpUseBreakEven,InpBreakEvenTriggerR,InpBreakEvenLockPoints,
                InpUseTrailing,InpTrailAtrMult,InpTrailStartR);

   Print("HighWinRateBot initialized on ",_Symbol," ",EnumToString(InpTimeframe));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_signal.Deinit();
  }

//+------------------------------------------------------------------+
//| New-bar detector                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t=iTime(_Symbol,InpTimeframe,0);
   if(t!=g_lastBarTime)
     {
      g_lastBarTime=t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- manage live trades on every tick (trailing/break-even)
   double atr=g_signal.GetATR(1);
   g_trade.ManageOpenPositions(atr);

   //--- entries evaluated once per closed bar
   bool newBar=IsNewBar();
   if(InpOnePerBar && !newBar)
      return;

   //--- risk gatekeeping
   string reason;
   if(!g_risk.CanOpenNewTrade(reason))
      return;

   //--- strategy signal
   ENUM_SIGNAL sig=g_signal.CheckSignal();
   if(sig==SIGNAL_NONE)
      return;

   if(atr<=0.0)
      return;

   //--- build SL/TP from ATR and intended R:R
   double slDist = InpAtrSlMult*atr;
   double tpDist = slDist*InpRewardRiskRatio;

   double entry,sl,tp;
   if(sig==SIGNAL_BUY)
     {
      entry = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      sl    = entry-slDist;
      tp    = entry+tpDist;
     }
   else
     {
      entry = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      sl    = entry+slDist;
      tp    = entry-tpDist;
     }

   //--- position size from risk %
   double lots=g_risk.CalcLotSize(slDist);
   if(lots<=0.0)
     {
      Print("Trade skipped: computed lot size is zero");
      return;
     }

   string comment=StringFormat("HWRBot %s R:R %.1f",
                               (sig==SIGNAL_BUY?"LONG":"SHORT"),InpRewardRiskRatio);

   if(g_trade.OpenTrade((int)sig,lots,sl,tp,comment))
     {
      g_risk.RegisterTradeOpened();
      PrintFormat("Opened %s  lots=%.2f  entry=%.5f  SL=%.5f  TP=%.5f  ATR=%.5f  dailyPnL=%.2f%%",
                  (sig==SIGNAL_BUY?"BUY":"SELL"),lots,entry,sl,tp,atr,g_risk.DailyProfitPct());
     }
  }
//+------------------------------------------------------------------+
