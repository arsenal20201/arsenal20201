//+------------------------------------------------------------------+
//|                                               HighWinRateEA.mq5   |
//|                  High Win-Rate Trend-Pullback Expert Advisor      |
//|                                                                  |
//|  Strategy summary                                                |
//|  ----------------                                                |
//|  Trade only in the direction of the dominant trend, entering on  |
//|  shallow pullbacks that are confirmed by momentum turning back   |
//|  in the trend direction. Trend-pullback systems tend to produce  |
//|  a high percentage of winners because entries are aligned with   |
//|  the prevailing move and stops are placed beyond recent swing    |
//|  structure (ATR based).                                          |
//|                                                                  |
//|  Confluence required for a LONG (mirror for SHORT):              |
//|    1. Fast EMA > Slow EMA            -> uptrend                   |
//|    2. Price above Slow EMA           -> trend confirmation        |
//|    3. ADX >= threshold               -> trend has strength        |
//|    4. Pullback: price touched/closed below Fast EMA recently      |
//|       OR RSI dipped below the pullback level                      |
//|    5. Momentum turn: RSI crosses back up through its level        |
//|       (Stochastic %K crossing %D up as optional confirmation)     |
//|                                                                  |
//|  Full money & trade management is implemented (see inputs).      |
//+------------------------------------------------------------------+
#property copyright "HighWinRateEA"
#property version   "1.00"
#property strict
#property description "Trend-pullback EA with ATR risk management, daily loss limit, break-even and trailing stop."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

//==================================================================
//  INPUTS
//==================================================================
input group "=== General ==="
input long     InpMagic            = 20240617;   // Magic number (unique per chart)
input string   InpTradeComment     = "HWR-EA";   // Order comment
input bool     InpAllowLong        = true;       // Allow long trades
input bool     InpAllowShort       = true;       // Allow short trades
input int      InpMaxSlippage      = 30;         // Max slippage (points)

input group "=== Trend Filter ==="
input int      InpFastEMA          = 20;         // Fast EMA period
input int      InpSlowEMA          = 50;         // Slow EMA period
input int      InpADXPeriod        = 14;         // ADX period
input double   InpADXMin           = 20.0;       // Minimum ADX (trend strength)

input group "=== Entry (Pullback + Momentum) ==="
input int      InpRSIPeriod        = 14;         // RSI period
input double   InpRSILongLevel     = 45.0;       // Long: RSI must dip below then cross up this
input double   InpRSIShortLevel    = 55.0;       // Short: RSI must rise above then cross down this
input int      InpPullbackLookback = 5;          // Bars to look back for the pullback
input bool     InpUseStochConfirm  = true;       // Require Stochastic confirmation
input int      InpStochK           = 14;         // Stochastic %K
input int      InpStochD           = 3;          // Stochastic %D
input int      InpStochSlow        = 3;          // Stochastic slowing

input group "=== Risk Management ==="
input double   InpRiskPercent      = 1.0;        // Risk per trade (% of equity)
input double   InpFixedLots        = 0.0;        // Fixed lots (0 = use risk %)
input double   InpATRPeriod        = 14;         // ATR period (for SL/TP)
input double   InpSLatrMult        = 1.5;        // Stop loss = ATR * this
input double   InpTPatrMult        = 2.25;       // Take profit = ATR * this (R:R)
input double   InpMinStopPoints     = 50;        // Minimum stop distance (points)

input group "=== Trade Management ==="
input bool     InpUseBreakEven     = true;       // Move to break-even
input double   InpBEtriggerATR      = 1.0;       // BE trigger = ATR * this (profit)
input double   InpBEoffsetPoints     = 20;       // BE offset above entry (points)
input bool     InpUseTrailing      = true;       // ATR trailing stop
input double   InpTrailStartATR      = 1.5;       // Start trailing after ATR * this profit
input double   InpTrailATRmult       = 2.0;       // Trail distance = ATR * this

input group "=== Exposure & Daily Limits ==="
input int      InpMaxPositions     = 1;          // Max simultaneous positions (this symbol/magic)
input int      InpMaxTradesPerDay  = 5;          // Max new trades per day (0 = unlimited)
input double   InpMaxDailyLossPct   = 3.0;        // Stop trading if daily loss exceeds % of equity
input double   InpMaxDailyProfitPct = 0.0;        // Stop trading after daily profit % (0 = off)
input double   InpMaxSpreadPoints   = 30;         // Skip entries if spread above (points)

input group "=== Session Filter (broker/server time) ==="
input bool     InpUseSession       = false;      // Restrict trading to a session
input int      InpSessionStartHour = 7;          // Session start hour
input int      InpSessionEndHour   = 20;         // Session end hour
input bool     InpTradeMonday      = true;
input bool     InpTradeFriday      = true;       // (set false to avoid Friday late risk)

//==================================================================
//  GLOBALS
//==================================================================
CTrade         trade;
CPositionInfo  position;
CSymbolInfo    sym;

int      hEMAfast = INVALID_HANDLE;
int      hEMAslow = INVALID_HANDLE;
int      hADX     = INVALID_HANDLE;
int      hRSI     = INVALID_HANDLE;
int      hATR     = INVALID_HANDLE;
int      hStoch   = INVALID_HANDLE;

datetime g_lastBarTime   = 0;       // for new-bar detection
datetime g_dayStart      = 0;       // start of current trading day
double   g_dayStartEquity = 0.0;    // equity at the start of the day
int      g_tradesToday    = 0;      // new entries opened today
bool     g_tradingBlocked = false;  // daily limit reached

//+------------------------------------------------------------------+
//| Helper: points -> price distance                                 |
//+------------------------------------------------------------------+
double PointsToPrice(double points) { return points * _Point; }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!sym.Name(_Symbol))
   {
      Print("Failed to init symbol info");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   hEMAfast = iMA(_Symbol, _Period, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEMAslow = iMA(_Symbol, _Period, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hADX     = iADX(_Symbol, _Period, InpADXPeriod);
   hRSI     = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   hATR     = iATR(_Symbol, _Period, (int)InpATRPeriod);
   hStoch   = iStochastic(_Symbol, _Period, InpStochK, InpStochD, InpStochSlow, MODE_SMA, STO_LOWHIGH);

   if(hEMAfast==INVALID_HANDLE || hEMAslow==INVALID_HANDLE || hADX==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE || hStoch==INVALID_HANDLE)
   {
      Print("Failed to create one or more indicator handles");
      return(INIT_FAILED);
   }

   if(InpFastEMA >= InpSlowEMA)
      Print("WARNING: Fast EMA period >= Slow EMA period. Check inputs.");

   ResetDay(true);

   Print("HighWinRateEA initialized on ", _Symbol, " ", EnumToString((ENUM_TIMEFRAMES)_Period));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMAfast!=INVALID_HANDLE) IndicatorRelease(hEMAfast);
   if(hEMAslow!=INVALID_HANDLE) IndicatorRelease(hEMAslow);
   if(hADX    !=INVALID_HANDLE) IndicatorRelease(hADX);
   if(hRSI    !=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR    !=INVALID_HANDLE) IndicatorRelease(hATR);
   if(hStoch  !=INVALID_HANDLE) IndicatorRelease(hStoch);
}

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // Refresh quotes
   if(!sym.RefreshRates())
      return;

   // --- Manage open positions on every tick (BE / trailing) ---
   ManageOpenPositions();

   // --- Daily roll-over / limit checks ---
   UpdateDailyState();

   // --- Only evaluate entries once per new bar ---
   if(!IsNewBar())
      return;

   if(g_tradingBlocked)
      return;

   if(!SessionAllowsTrading())
      return;

   if(CountMyPositions() >= InpMaxPositions)
      return;

   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay)
      return;

   // Spread filter
   double spreadPts = (sym.Ask() - sym.Bid()) / _Point;
   if(spreadPts > InpMaxSpreadPoints)
      return;

   // Evaluate signals
   int signal = GetSignal();
   if(signal > 0 && InpAllowLong)
      OpenTrade(ORDER_TYPE_BUY);
   else if(signal < 0 && InpAllowShort)
      OpenTrade(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Signal engine: returns +1 long, -1 short, 0 none                 |
//| Uses closed bar (shift 1) to avoid repainting.                   |
//+------------------------------------------------------------------+
int GetSignal()
{
   double emaFast[2], emaSlow[2], adx[2], rsi[3], stochK[2], stochD[2];

   // Index 0 = most recent CLOSED bar (shift 1), index grows into the past.
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(adx,     true);
   ArraySetAsSeries(rsi,     true);
   ArraySetAsSeries(stochK,  true);
   ArraySetAsSeries(stochD,  true);

   if(CopyBuffer(hEMAfast, 0, 1, 2, emaFast) < 2) return 0;
   if(CopyBuffer(hEMAslow, 0, 1, 2, emaSlow) < 2) return 0;
   if(CopyBuffer(hADX,     0, 1, 2, adx)     < 2) return 0;
   if(CopyBuffer(hRSI,     0, 1, 3, rsi)     < 3) return 0;
   if(CopyBuffer(hStoch,   0, 1, 2, stochK)  < 2) return 0; // main line
   if(CopyBuffer(hStoch,   1, 1, 2, stochD)  < 2) return 0; // signal line

   double close1 = iClose(_Symbol, _Period, 1);

   // Arrays are as-series: index 0 = shift 1 (most recent closed), index 1 = older.
   double emaFastNow = emaFast[0];
   double emaSlowNow = emaSlow[0];
   double adxNow     = adx[0];
   double rsiNow     = rsi[0];   // closed bar 1
   double rsiPrev    = rsi[1];   // closed bar 2

   // Trend strength gate
   if(adxNow < InpADXMin)
      return 0;

   //=========================== LONG ===============================
   bool upTrend   = (emaFastNow > emaSlowNow) && (close1 > emaSlowNow);
   if(upTrend)
   {
      // Pullback: within lookback the price dipped to/under the fast EMA
      bool pulledBack = false;
      for(int i = 1; i <= InpPullbackLookback; i++)
      {
         double lo = iLow(_Symbol, _Period, i);
         double ef[1];
         if(CopyBuffer(hEMAfast, 0, i, 1, ef) == 1)
            if(lo <= ef[0]) { pulledBack = true; break; }
      }

      // Momentum turn: RSI crossed back up through long level
      bool rsiTurnUp = (rsiPrev <= InpRSILongLevel && rsiNow > InpRSILongLevel);

      // Optional Stochastic confirmation: %K crossing above %D from a low
      bool stochOK = true;
      if(InpUseStochConfirm)
         stochOK = (stochK[1] <= stochD[1] && stochK[0] > stochD[0]);

      if(pulledBack && rsiTurnUp && stochOK)
         return +1;
   }

   //=========================== SHORT ==============================
   bool downTrend = (emaFastNow < emaSlowNow) && (close1 < emaSlowNow);
   if(downTrend)
   {
      bool pulledBack = false;
      for(int i = 1; i <= InpPullbackLookback; i++)
      {
         double hi = iHigh(_Symbol, _Period, i);
         double ef[1];
         if(CopyBuffer(hEMAfast, 0, i, 1, ef) == 1)
            if(hi >= ef[0]) { pulledBack = true; break; }
      }

      bool rsiTurnDown = (rsiPrev >= InpRSIShortLevel && rsiNow < InpRSIShortLevel);

      bool stochOK = true;
      if(InpUseStochConfirm)
         stochOK = (stochK[1] >= stochD[1] && stochK[0] < stochD[0]);

      if(pulledBack && rsiTurnDown && stochOK)
         return -1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Current ATR value (closed bar)                                   |
//+------------------------------------------------------------------+
double GetATR()
{
   double atr[1];
   if(CopyBuffer(hATR, 0, 1, 1, atr) == 1)
      return atr[0];
   return 0.0;
}

//+------------------------------------------------------------------+
//| Position sizing from risk % and stop distance                    |
//+------------------------------------------------------------------+
double CalcLotSize(double stopDistancePrice)
{
   // Fixed lots override
   if(InpFixedLots > 0.0)
      return NormalizeLots(InpFixedLots);

   if(stopDistancePrice <= 0.0)
      return 0.0;

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;

   // Loss per 1 lot for the given stop distance
   double lossPerLot = (stopDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;

   double lots = riskMoney / lossPerLot;
   return NormalizeLots(lots);
}

//+------------------------------------------------------------------+
//| Normalize lots to broker constraints                             |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0.0) lotStep = 0.01;
   lots = MathFloor(lots / lotStep) * lotStep;

   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Open a new trade with ATR SL/TP and risk-based size              |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
{
   double atr = GetATR();
   if(atr <= 0.0) return;

   double slDist = atr * InpSLatrMult;
   double tpDist = atr * InpTPatrMult;

   double minStop = PointsToPrice(InpMinStopPoints);
   double brokerStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double floorStop  = MathMax(minStop, brokerStop);
   if(slDist < floorStop) slDist = floorStop;

   double price, sl, tp;
   if(type == ORDER_TYPE_BUY)
   {
      price = sym.Ask();
      sl    = price - slDist;
      tp    = price + tpDist;
   }
   else
   {
      price = sym.Bid();
      sl    = price + slDist;
      tp    = price - tpDist;
   }

   double lots = CalcLotSize(slDist);
   if(lots <= 0.0)
   {
      Print("Lot size computed as 0 - trade skipped");
      return;
   }

   price = NormalizeDouble(price, _Digits);
   sl    = NormalizeDouble(sl, _Digits);
   tp    = NormalizeDouble(tp, _Digits);

   bool ok;
   if(type == ORDER_TYPE_BUY)
      ok = trade.Buy(lots, _Symbol, price, sl, tp, InpTradeComment);
   else
      ok = trade.Sell(lots, _Symbol, price, sl, tp, InpTradeComment);

   if(ok)
   {
      g_tradesToday++;
      PrintFormat("Opened %s %.2f lots @ %.5f SL=%.5f TP=%.5f (ATR=%.5f, risk=%.2f%%)",
                  (type==ORDER_TYPE_BUY?"BUY":"SELL"), lots, price, sl, tp, atr, InpRiskPercent);
   }
   else
   {
      PrintFormat("Order failed: retcode=%d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Manage open positions: break-even + ATR trailing                 |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(!InpUseBreakEven && !InpUseTrailing)
      return;

   double atr = GetATR();
   if(atr <= 0.0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!position.SelectByTicket(ticket)) continue;
      if(position.Symbol() != _Symbol) continue;
      if(position.Magic() != InpMagic) continue;

      ENUM_POSITION_TYPE ptype = position.PositionType();
      double openPrice = position.PriceOpen();
      double curSL     = position.StopLoss();
      double curTP     = position.TakeProfit();
      double bid       = sym.Bid();
      double ask       = sym.Ask();

      double newSL = curSL;

      //----------------- Break-even --------------------------------
      if(InpUseBreakEven)
      {
         double beTrigger = atr * InpBEtriggerATR;
         double offset    = PointsToPrice(InpBEoffsetPoints);

         if(ptype == POSITION_TYPE_BUY)
         {
            if(bid - openPrice >= beTrigger)
            {
               double be = openPrice + offset;
               if(curSL < be) newSL = be;
            }
         }
         else // SELL
         {
            if(openPrice - ask >= beTrigger)
            {
               double be = openPrice - offset;
               if(curSL == 0.0 || curSL > be) newSL = be;
            }
         }
      }

      //----------------- ATR trailing ------------------------------
      if(InpUseTrailing)
      {
         double trailStart = atr * InpTrailStartATR;
         double trailDist  = atr * InpTrailATRmult;

         if(ptype == POSITION_TYPE_BUY)
         {
            if(bid - openPrice >= trailStart)
            {
               double t = bid - trailDist;
               if(t > newSL) newSL = t;
            }
         }
         else // SELL
         {
            if(openPrice - ask >= trailStart)
            {
               double t = ask + trailDist;
               if(newSL == 0.0 || t < newSL) newSL = t;
            }
         }
      }

      // Apply modification if SL improved
      if(newSL != curSL && newSL > 0.0)
      {
         newSL = NormalizeDouble(newSL, _Digits);
         // Respect broker stop level
         double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
         bool valid = true;
         if(ptype == POSITION_TYPE_BUY  && (bid - newSL) < stopLevel) valid = false;
         if(ptype == POSITION_TYPE_SELL && (newSL - ask) < stopLevel) valid = false;

         if(valid)
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Count my open positions (this symbol + magic)                    |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!position.SelectByTicket(ticket)) continue;
      if(position.Symbol() == _Symbol && position.Magic() == InpMagic)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Session / day filter                                             |
//+------------------------------------------------------------------+
bool SessionAllowsTrading()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(!InpTradeMonday && dt.day_of_week == 1) return false;
   if(!InpTradeFriday && dt.day_of_week == 5) return false;
   // Skip weekends entirely
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;

   if(!InpUseSession)
      return true;

   int h = dt.hour;
   if(InpSessionStartHour <= InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);
   else // session wraps midnight
      return (h >= InpSessionStartHour || h < InpSessionEndHour);
}

//+------------------------------------------------------------------+
//| Daily reset helper                                               |
//+------------------------------------------------------------------+
void ResetDay(bool force)
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   if(force || today != g_dayStart)
   {
      g_dayStart        = today;
      g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradesToday     = 0;
      g_tradingBlocked  = false;
   }
}

//+------------------------------------------------------------------+
//| Update daily P/L limits                                          |
//+------------------------------------------------------------------+
void UpdateDailyState()
{
   ResetDay(false);

   if(g_dayStartEquity <= 0.0)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double pnlPct = (equity - g_dayStartEquity) / g_dayStartEquity * 100.0;

   if(InpMaxDailyLossPct > 0.0 && pnlPct <= -InpMaxDailyLossPct)
   {
      if(!g_tradingBlocked)
         PrintFormat("Daily loss limit hit (%.2f%%). Trading blocked until next day.", pnlPct);
      g_tradingBlocked = true;
   }

   if(InpMaxDailyProfitPct > 0.0 && pnlPct >= InpMaxDailyProfitPct)
   {
      if(!g_tradingBlocked)
         PrintFormat("Daily profit target hit (%.2f%%). Trading blocked until next day.", pnlPct);
      g_tradingBlocked = true;
   }
}
//+------------------------------------------------------------------+
