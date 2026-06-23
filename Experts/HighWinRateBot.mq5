//+------------------------------------------------------------------+
//|                                              HighWinRateBot.mq5   |
//|        High Win-Rate RSI Mean-Reversion EA for MetaTrader 5 (v3)  |
//|                                                                  |
//|  v3 drops the over-filtered v2 approach for a clean, proven      |
//|  high-win-rate style: buy oversold dips in an uptrend / sell     |
//|  overbought rips in a downtrend (short-period RSI cross + trend  |
//|  EMA). Optional gates (HTF, ADX, confirm candle) default OFF.    |
//|  Risk: structure-based stops, %-equity sizing, daily loss limit, |
//|  profit lock, max positions/trades, spread + session filters,    |
//|  consecutive-loss cooldown, scale-out partial TP, break-even,    |
//|  ATR trailing. MT5 natively draws each position's entry/SL/TP.   |
//|                                                                  |
//|  NOTE: Educational tool. Forward-test on DEMO before going live. |
//+------------------------------------------------------------------+
#property copyright "HighWinRateBot"
#property link      "https://github.com/arsenal20201/arsenal20201"
#property version   "3.00"
#property strict

#include <HWRBot/SignalEngine.mqh>
#include <HWRBot/RiskManager.mqh>
#include <HWRBot/TradeManager.mqh>

//--- Strategy core ---------------------------------------------------
input group "=== Strategy (RSI mean reversion) ==="
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_M15;   // Working timeframe
input int    InpRsiPeriod              = 3;            // RSI period (short = mean reversion)
input double InpRsiOversold            = 15.0;         // Oversold level (long entries)
input double InpRsiOverbought          = 85.0;         // Overbought level (short entries)
input bool   InpUseTrend               = true;         // Trade only with the trend EMA
input int    InpTrendEmaPeriod         = 200;          // Trend EMA period
input int    InpAtrPeriod              = 14;           // ATR period

//--- Optional filters (default OFF) ---------------------------------
input group "=== Optional Filters ==="
input bool   InpUseHtfFilter           = false;        // Require higher-TF trend agreement
input ENUM_TIMEFRAMES InpHtfTimeframe  = PERIOD_H4;    // Higher timeframe
input int    InpHtfEmaPeriod           = 200;          // Higher-TF EMA period
input bool   InpUseAdx                 = false;        // Require ADX trend strength
input int    InpAdxPeriod              = 14;           // ADX / DMI period
input double InpAdxMin                 = 18.0;         // Min ADX to trade
input bool   InpConfirmBar             = false;        // Require confirmation candle

//--- Stops & targets ------------------------------------------------
input group "=== Stops & Targets ==="
input bool   InpUseSwingStop           = true;         // Structure (swing) stop
input int    InpSwingLook              = 10;           // Swing lookback (bars)
input double InpStopBufAtr             = 0.3;          // Stop buffer beyond swing (ATR x)
input double InpAtrSlMult              = 1.5;          // Min stop = ATR x
input double InpMaxStopAtr             = 3.5;          // Max stop = ATR x
input double InpRewardRiskRatio        = 1.5;          // Take-profit R:R
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
   if(InpRsiOversold>=InpRsiOverbought)
     { Print("Init error: Oversold level must be below Overbought level"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskPercent<=0.0 || InpRiskPercent>20.0)
     { Print("Init error: Risk percent should be in (0, 20]"); return INIT_PARAMETERS_INCORRECT; }
   if(InpAtrSlMult<=0.0 || InpRewardRiskRatio<=0.0 || InpMaxStopAtr<InpAtrSlMult)
     { Print("Init error: check ATR SL / max-stop / R:R values"); return INIT_PARAMETERS_INCORRECT; }
   if(InpUsePartialTP && (InpPartialPercent<=0.0 || InpPartialPercent>=100.0))
     { Print("Init error: Partial percent must be between 0 and 100"); return INIT_PARAMETERS_INCORRECT; }

   if(!g_signal.Init(_Symbol,InpTimeframe,
                     InpRsiPeriod,InpRsiOversold,InpRsiOverbought,InpAtrPeriod,
                     InpUseTrend,InpTrendEmaPeriod,
                     InpUseHtfFilter,InpHtfTimeframe,InpHtfEmaPeriod,
                     InpUseAdx,InpAdxPeriod,InpAdxMin,
                     InpConfirmBar,
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

   Print("HighWinRateBot v3.00 initialized on ",_Symbol," ",EnumToString(InpTimeframe));
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
   if(trans.deal==0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;

   //--- BUGFIX: a scale-out partial is also a DEAL_ENTRY_OUT. Only update the
   //--- loss streak once the WHOLE position is closed, using its total P/L.
   ulong posId=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   if(PositionSelectByTicket(posId)) return;   // still partly open -> wait

   double profit=0.0;
   if(HistorySelectByPosition(posId))
     {
      int deals=HistoryDealsTotal();
      for(int i=0;i<deals;i++)
        {
         ulong d=HistoryDealGetTicket(i);
         if(d==0) continue;
         profit += HistoryDealGetDouble(d,DEAL_PROFIT)
                 + HistoryDealGetDouble(d,DEAL_SWAP)
                 + HistoryDealGetDouble(d,DEAL_COMMISSION);
        }
     }
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
