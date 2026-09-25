//+------------------------------------------------------------------+
//|                                           EA_RoboFibo_v11.2.mq5  |
//|        MQL5 port of "Expert Advisor RoboFibo v.11" (src v11.2)   |
//|                                                                  |
//|  Strategy (see docs/RoboFibo_Strategy_Analysis.md for details)   |
//|  --------                                                        |
//|  * A Fibonacci range is built from the highest high / lowest low |
//|    of the last BarsBack bars of the chart timeframe.             |
//|  * When price is in the lower (<LowFibo) or upper (>HighFibo)    |
//|    zone of that range a pending order is armed PendingDistance   |
//|    points away from price and TRAILED with price every tick, so  |
//|    it only fills after a PendingDistance-point reversal.         |
//|  * If the basket goes against us, further pending orders are     |
//|    armed after the price moved PendingDistance + Pipstep*        |
//|    PipstepExponent^n points (widening grid), lots grow by        |
//|    LotsExponent^n (mild martingale).                             |
//|  * All positions of one side share one take-profit placed        |
//|    TakeProfitAll points beyond the volume-weighted average.      |
//|  * Optional: money TP/SL per basket, trailing, virtual trailing, |
//|    spread(+commission) filter, news filter.                      |
//|                                                                  |
//|  Differences vs. the MQL4 original                               |
//|  ---------------------------------                               |
//|  * Native MQL5 trading (CTrade), no stdlib.ex4 / Wininet.dll.    |
//|  * News filter uses the built-in MT5 Economic Calendar instead   |
//|    of the dead forexfactory XML feed (the original downloaded it |
//|    on every tick because barw1 was never updated).               |
//|  * Bug fixes: lot sizes are rounded to the broker's volume step  |
//|    (the original produced 0.011, 0.0121 ... -> "invalid volume"),|
//|    grid trigger no longer re-uses a stale value from a previous  |
//|    tick when the candle filter fails, close loops no longer skip |
//|    orders, virtual SL/TP work without virtual trailing, basket   |
//|    already beyond its TP is closed instead of spamming invalid   |
//|    modify requests, uninitialised signal variable, array         |
//|    out-of-range in the news code.                                |
//|  * Optional extra protections (all OFF by default so the EA      |
//|    behaves like the original unless you enable them).            |
//|                                                                  |
//|  REQUIRES A HEDGING ACCOUNT (buy and sell baskets coexist).      |
//+------------------------------------------------------------------+
#property copyright   "Copyright © 2017 Expert Advisor RoboFibo v.11 By Yonif - MQL5 port"
#property link        "www.hobiheboh.com"
#property version     "11.20"
#property description "MQL5 port of EA RoboFibo v.11 (source v11.2)."
#property description "Fibonacci-zone trailing pending orders + widening grid with basket take-profit."
#property description "Requires a HEDGING account."

#include <Trade/Trade.mqh>

//==================================================================
//  ENUMS
//==================================================================
enum ENUM_Trading_Mode
  {
   PendingLimitFollow,
   PendingLimitReverse,
   PendingStopFollow,
   PendingStopReverse,
  };

enum Corner
  {
   left  = 0, //Left side
   right = 1, //Right side
  };

enum ENUM_MinimumImpact
  {
   LowImpact,
   MediumImpact,
   HighImpact,
  };

//==================================================================
//  INPUTS  (names kept identical to the MQL4 version)
//==================================================================
input group "=== Trading mode ==="
input ENUM_Trading_Mode TradingMode   = PendingStopReverse;

input group "=== Lots / money management ==="
input bool     UseMM                  = false;
input double   Risk                   = 0.1;     // Risk % of (balance * leverage) when UseMM
input double   FixedLots              = 0.01;
input double   LotsExponent           = 1.1;     // Lot multiplier per open trade of the same side

input group "=== Per-order TP / SL (points) ==="
input bool     UseTakeProfit          = false;
input bool     VirtualTakeProfit      = false;
input int      TakeProfit             = 500;
input bool     UseStopLoss            = false;
input bool     VirtualStopLoss        = false;
input int      StopLoss               = 500;

input group "=== Basket take-profit / money targets ==="
input bool     UseTakeProfitAll       = true;
input int      TakeProfitAll          = 20;      // Points beyond the basket average price
input bool     AutoTargetMoney        = false;
input double   TargetMoneyFactor      = 20.0;
input double   TargetMoney            = 0.0;     // Close basket at this profit (account ccy), 0 = off
input bool     AutoStopLossMoney      = false;
input double   StoplossFactor         = 0.0;
input double   StoplossMoney          = 0.0;     // Close basket at this loss (account ccy), 0 = off

input group "=== Trailing ==="
input bool     UseTrailing            = false;
input int      TrailingStop           = 20;
input int      TrailingStart          = 20;
input bool     UseVirtualTrailing     = false;
input int      VirtualTrailingStart   = 10;
input int      VirtualTrailingStop    = 10;
input int      VirtualTrailingStep    = 0;

input group "=== Grid ==="
input int      CandlestickHighLow     = 500;     // Add to grid only if bar 0 and bar 1 range <= this (points)
input int      MaxOrderBuy            = 30;
input int      MaxOrderSell           = 30;
input int      PendingDistance        = 20;      // Distance of the trailing pending order (points)
input int      Pipstep                = 50;      // Base grid step (points)
input double   PipstepExponent        = 1.5;     // Grid step multiplier per open trade

input group "=== Signal / filters ==="
input ENUM_TIMEFRAMES IClose          = PERIOD_H1;
input ENUM_TIMEFRAMES IRSI            = PERIOD_H1;
input ENUM_TIMEFRAMES ma1             = PERIOD_H1;
input int      RSIPeriod              = 14;
input int      maperiod               = 60;
input double   MaxSpreadPlusCommission= 50.0;    // Points
input double   HighFibo               = 76.4;
input double   LowFibo                = 23.6;
input int      StartBar               = 0;
input int      BarsBack               = 20;

input group "=== News filter (MT5 Economic Calendar, live only) ==="
input bool     NewsFilter             = true;
input int      UpdateHour             = 4;       // Reload calendar every N hours
input int      DisableMinBeforeNews   = 60;
input int      EnableMinAfterNews     = 60;
input ENUM_MinimumImpact MinimumImpactNews = HighImpact;
input bool     ForceALL               = true;
input bool     ForceAUD               = true;
input bool     ForceCAD               = true;
input bool     ForceCHF               = true;
input bool     ForceCNY               = true;
input bool     ForceEUR               = true;
input bool     ForceGBP               = true;
input bool     ForceJPY               = true;
input bool     ForceNZD               = true;
input bool     ForceUSD               = true;

input group "=== Panel ==="
input Corner   Side                   = left;
input color    Textcolor              = clrBlack;
input color    Backgroundcolor        = clrDarkOrchid;
input color    Backgroundcolor2       = clrBlue;
input color    Backgroundcolor3       = clrRed;
input color    Backgroundcolor4       = clrYellow;
input color    Backgroundcolor5       = clrGreen;

input group "=== General ==="
input int      Slippage               = 10;
input int      MagicNumber            = 1;
input string   TradeComment           = "EA RoboFibo v.11";

input group "=== Extra protection (new in MQL5 port; 0/false = original behaviour) ==="
input double   MaxDrawdownPercent     = 0.0;     // Close all EA trades if EA floating loss >= X% of balance (0=off)
input double   MaxLotsPerOrder        = 0.0;     // Hard cap per order (0 = broker max / 100)
input bool     DeletePendingOnNews    = false;   // Delete pending orders during the news blackout
input int      MinModifyStep          = 0;       // Move a trailing pending only if it moves >= N points (0 = every tick)

//==================================================================
//  CONSTANTS / GLOBALS
//==================================================================
#define OBJ_PREFIX  "RF_"
#define SPREAD_HIST 30

const double MaxLots       = 100.0;
const int    StartHour     = 0;
const int    StartMinute   = 0;
const int    EndHour       = 23;
const int    EndMinute     = 59;
const double Fibo_Level_0  = 0.000;
const double Fibo_Level_1  = 0.236;
const double Fibo_Level_2  = 0.382;
const double Fibo_Level_3  = 0.500;
const double Fibo_Level_4  = 0.618;
const double Fibo_Level_5  = 0.764;
const double Fibo_Level_6  = 1.000;
const color  VerticalLinesColor = clrBlue;
const color  FiboLinesColors    = clrDarkGray;

CTrade   trade;
int      hRSI = INVALID_HANDLE;
int      hMA  = INVALID_HANDLE;

double   Ask = 0, Bid = 0;
int      stoplevel      = 0;        // points
double   stoplevelPrice = 0;        // price units ("sellstop" in the original)

double   g_minLot = 0, g_maxLot = 0, g_lotStep = 0;
int      g_lotDigits = 2;
double   g_riskFrac = 0;
double   g_maxSpread = 0;
double   g_pendDist = 0, g_slDist = 0, g_tpDist = 0;
double   g_candleRange = 0;

bool     g_commKnown = false;
datetime g_commLastTry = 0;
double   g_commPrice = 0;           // commission expressed in price units

double   g_spread[SPREAD_HIST];
int      g_spreadCount = 0;

double   totalProfits = 0, totalProfits2 = 0;
bool     CloseSignal = false, CloseSignal2 = false;
double   TPbuy = 0, TPsell = 0, SLbuy = 0, SLsell = 0;
double   TrallB = 0, TrallS = 0;
int      g_haltDay = -1;

double   close1 = 0, close2 = 0, rsia = 0, rsib = 0, ma = 0;
string   sign = "", sign2 = "", sign3 = "", status1 = "";

// commission cache for open positions (entry commission by position id)
ulong    g_commId[];
double   g_commVal[];

// news
int      MinimumImpact = 3;
string   s1 = "", s2 = "";
datetime g_newsLastUpdate = 0;
datetime g_newsTime[];
int      g_newsImpact[];
string   g_newsTitle[];
string   g_newsCur[];
long     prevnews = 99999, nextnews = -1;
string   title0 = "", country0 = "", date0 = "";
string   titlex = "", countryx = "", datex = "";

//==================================================================
//  INIT / DEINIT
//==================================================================
int OnInit()
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Alert("EA RoboFibo: this EA needs a HEDGING account (buy and sell baskets are held at the same time).");
      return(INIT_FAILED);
     }

   switch(MinimumImpactNews)
     {
      case LowImpact:    MinimumImpact = 1; break;
      case MediumImpact: MinimumImpact = 2; break;
      default:           MinimumImpact = 3; break;
     }

   g_minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(g_lotStep <= 0) g_lotStep = 0.01;
   g_lotDigits = (int)MathMax(0, MathCeil(-MathLog10(g_lotStep) - 1e-9));

   g_riskFrac    = Risk / 100.0;
   g_maxSpread   = NormalizeDouble(MaxSpreadPlusCommission * _Point, _Digits + 1);
   g_pendDist    = NormalizeDouble(PendingDistance * _Point, _Digits);
   g_slDist      = NormalizeDouble(StopLoss * _Point, _Digits);
   g_tpDist      = NormalizeDouble(TakeProfit * _Point, _Digits);
   g_candleRange = NormalizeDouble(CandlestickHighLow * _Point, _Digits);
   ArrayInitialize(g_spread, 0);
   g_spreadCount = 0;

   s1 = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   s2 = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   hRSI = iRSI(_Symbol, IRSI, RSIPeriod, PRICE_CLOSE);
   hMA  = iMA(_Symbol, ma1, maperiod, 0, MODE_EMA, PRICE_CLOSE);
   if(hRSI == INVALID_HANDLE || hMA == INVALID_HANDLE)
     {
      Print("EA RoboFibo: failed to create indicator handles, error ", GetLastError());
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();
   trade.LogLevel(LOG_LEVEL_ERRORS);

   Print("Digits: ", _Digits, " Point: ", DoubleToString(_Point, _Digits),
         " LotStep: ", DoubleToString(g_lotStep, g_lotDigits));

   ObjectsDeleteAll(0, OBJ_PREFIX);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   Comment("");
   ObjectsDeleteAll(0, OBJ_PREFIX);
   if(hRSI != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMA  != INVALID_HANDLE) IndicatorRelease(hMA);
  }

//==================================================================
//  SMALL HELPERS
//==================================================================
double N(const double price) { return NormalizeDouble(price, _Digits); }

bool IsOurs(const string sym, const long magic)
  {
   if(sym != _Symbol) return(false);
   if(MagicNumber == 0) return(true);
   return(magic == MagicNumber);
  }

bool SelectOurPosition(const int index, ulong &ticket)
  {
   ticket = PositionGetTicket(index);
   if(ticket == 0) return(false);
   return(IsOurs(PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_MAGIC)));
  }

int DayOfYearNow()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return(dt.year * 1000 + dt.day_of_year);
  }

double NormalizeLot(double v)
  {
   double lo = MathMax(FixedLots, g_minLot);
   double hi = MathMin(MaxLots, g_maxLot);
   if(MaxLotsPerOrder > 0) hi = MathMin(hi, MaxLotsPerOrder);
   v = MathRound(v / g_lotStep) * g_lotStep;
   v = MathMax(lo, v);
   v = MathMin(hi, v);
   v = MathFloor(v / g_lotStep + 1e-7) * g_lotStep;   // keep on the volume step after clamping
   if(v < g_minLot) v = g_minLot;
   return(NormalizeDouble(v, g_lotDigits));
  }

// Ld_196 in the original: base lot before the martingale exponent
double BaseLot()
  {
   if(!UseMM) return(FixedLots);
   double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contract <= 0) return(FixedLots);
   return(AccountInfoDouble(ACCOUNT_BALANCE) * (double)AccountInfoInteger(ACCOUNT_LEVERAGE) * g_riskFrac / contract);
  }

//==================================================================
//  POSITION / BASKET QUERIES
//==================================================================
int CountTrades(const ENUM_POSITION_TYPE type)
  {
   int c = 0;
   ulong tk;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(SelectOurPosition(i, tk) && (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type) c++;
   return(c);
  }
int CountTradesBuy()  { return(CountTrades(POSITION_TYPE_BUY));  }
int CountTradesSell() { return(CountTrades(POSITION_TYPE_SELL)); }

// open price of the most recent position (highest ticket) of a side
double FindLastPrice(const ENUM_POSITION_TYPE type)
  {
   ulong best = 0, tk;
   double price = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectOurPosition(i, tk)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      if(tk > best) { best = tk; price = PositionGetDouble(POSITION_PRICE_OPEN); }
     }
   return(price);
  }

bool BasketAverage(const ENUM_POSITION_TYPE type, double &avg, double &lots)
  {
   double w = 0;
   lots = 0;
   ulong tk;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectOurPosition(i, tk)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      w    += PositionGetDouble(POSITION_PRICE_OPEN) * v;
      lots += v;
     }
   avg = (lots > 0) ? w / lots : 0;
   return(lots > 0);
  }

double EntryCommission(const long posId)
  {
   int n = ArraySize(g_commId);
   for(int i = 0; i < n; i++)
      if(g_commId[i] == (ulong)posId) return(g_commVal[i]);
   double c = 0;
   bool found = false;
   if(HistorySelectByPosition(posId))
     {
      for(int j = HistoryDealsTotal() - 1; j >= 0; j--)
        {
         ulong d = HistoryDealGetTicket(j);
         if(d == 0) continue;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
           {
            c += HistoryDealGetDouble(d, DEAL_COMMISSION);
            found = true;
           }
        }
     }
   if(found)
     {
      if(n > 500) { ArrayResize(g_commId, 0); ArrayResize(g_commVal, 0); n = 0; }
      ArrayResize(g_commId, n + 1);
      ArrayResize(g_commVal, n + 1);
      g_commId[n]  = (ulong)posId;
      g_commVal[n] = c;
     }
   return(c);
  }

double BasketProfit(const ENUM_POSITION_TYPE type)
  {
   double p = 0;
   ulong tk;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectOurPosition(i, tk)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      long id = PositionGetInteger(POSITION_IDENTIFIER);
      p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      p += EntryCommission(id);
     }
   return(p);
  }

void TotalProfitbuy()  { totalProfits  = BasketProfit(POSITION_TYPE_BUY);  }
void TotalProfitsell() { totalProfits2 = BasketProfit(POSITION_TYPE_SELL); }

//==================================================================
//  CLOSE HELPERS
//==================================================================
bool IsBuyPending(const ENUM_ORDER_TYPE t)  { return(t == ORDER_TYPE_BUY_LIMIT  || t == ORDER_TYPE_BUY_STOP);  }
bool IsSellPending(const ENUM_ORDER_TYPE t) { return(t == ORDER_TYPE_SELL_LIMIT || t == ORDER_TYPE_SELL_STOP); }

void CloseSide(const ENUM_POSITION_TYPE type, const bool deletePending)
  {
   ulong tk;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectOurPosition(i, tk)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      if(!trade.PositionClose(tk, Slippage))
         Print(" PositionClose failed #", tk, " retcode ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
     }
   if(!deletePending) return;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ot = OrderGetTicket(i);
      if(ot == 0) continue;
      if(!IsOurs(OrderGetString(ORDER_SYMBOL), OrderGetInteger(ORDER_MAGIC))) continue;
      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if((type == POSITION_TYPE_BUY && IsBuyPending(t)) || (type == POSITION_TYPE_SELL && IsSellPending(t)))
         if(!trade.OrderDelete(ot))
            Print(" OrderDelete failed #", ot, " retcode ", trade.ResultRetcode());
     }
  }

void OpenOrdClose()  { CloseSide(POSITION_TYPE_BUY,  true); }
void OpenOrdClose2() { CloseSide(POSITION_TYPE_SELL, true); }

void DeleteAllPending()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ot = OrderGetTicket(i);
      if(ot == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(IsBuyPending(t) || IsSellPending(t)) trade.OrderDelete(ot);
     }
  }

//==================================================================
//  ACCOUNT / HISTORY
//==================================================================
// Estimate commission (in price units) from the last closed trade on this symbol (Gd_272 in the original)
void EstimateCommission()
  {
   if(g_commKnown) return;
   datetime now = TimeCurrent();
   if(g_commLastTry != 0 && now - g_commLastTry < 3600) return;
   g_commLastTry = now;
   if(!HistorySelect(now - 90 * 86400, now + 86400)) return;

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      double profit = HistoryDealGetDouble(d, DEAL_PROFIT);
      if(profit == 0.0) continue;
      double closePrice = HistoryDealGetDouble(d, DEAL_PRICE);
      double outComm    = HistoryDealGetDouble(d, DEAL_COMMISSION);
      long   pid        = HistoryDealGetInteger(d, DEAL_POSITION_ID);

      double openPrice = 0, inComm = 0;
      bool found = false;
      for(int j = i - 1; j >= 0; j--)
        {
         ulong e = HistoryDealGetTicket(j);
         if(e == 0) continue;
         if(HistoryDealGetInteger(e, DEAL_POSITION_ID) == pid && HistoryDealGetInteger(e, DEAL_ENTRY) == DEAL_ENTRY_IN)
           {
            openPrice = HistoryDealGetDouble(e, DEAL_PRICE);
            inComm    = HistoryDealGetDouble(e, DEAL_COMMISSION);
            found = true;
            break;
           }
        }
      if(!found || closePrice == openPrice) continue;
      double moneyPerPrice = MathAbs(profit / (closePrice - openPrice));
      if(moneyPerPrice <= 0) continue;
      g_commPrice = -(inComm + outComm) / moneyPerPrice;
      g_commKnown = true;
      break;
     }
  }

// Balance at the start of the day (all symbols, trading deals only)
double startBalanceD1()
  {
   double vProfit = 0;
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart > 0 && HistorySelect(dayStart, TimeCurrent() + 60))
     {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         long t = HistoryDealGetInteger(d, DEAL_TYPE);
         if(t != DEAL_TYPE_BUY && t != DEAL_TYPE_SELL) continue;
         vProfit += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_SWAP);
        }
     }
   return(NormalizeDouble(AccountInfoDouble(ACCOUNT_BALANCE) - vProfit, 2));
  }

// Trading hours (f0_4 in the original; effectively 00:00 - 23:59 server time)
bool f0_4()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if((dt.hour > StartHour && dt.hour < EndHour) || (dt.hour == StartHour && dt.min >= StartMinute) || (dt.hour == EndHour && dt.min < EndMinute))
      return(true);
   return(false);
  }

//==================================================================
//  EXTRA PROTECTION (new)
//==================================================================
void CheckDrawdownGuard()
  {
   if(MaxDrawdownPercent <= 0) return;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double floating = totalProfits + totalProfits2;
   if(bal > 0 && -floating >= bal * MaxDrawdownPercent / 100.0)
     {
      PrintFormat("EA RoboFibo: floating loss %.2f >= %.1f%% of balance, closing everything and pausing until tomorrow.",
                  floating, MaxDrawdownPercent);
      CloseSide(POSITION_TYPE_BUY, true);
      CloseSide(POSITION_TYPE_SELL, true);
      g_haltDay = DayOfYearNow();
     }
  }

//==================================================================
//  PENDING ORDER PRICING
//==================================================================
void PendingDistances(double &dist, double &slD, double &tpD)
  {
   dist = (PendingDistance <= stoplevel) ? stoplevelPrice : g_pendDist;
   slD  = (StopLoss        <= stoplevel) ? stoplevelPrice : g_slDist;
   tpD  = (TakeProfit      <= stoplevel) ? stoplevelPrice : g_tpDist;
  }

// price / sl / tp for a pending order of this type at the current market
void PendingPrices(const ENUM_ORDER_TYPE type, double &price, double &sl, double &tp)
  {
   double dist, slD, tpD;
   PendingDistances(dist, slD, tpD);
   bool isBuy = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT);
   switch(type)
     {
      case ORDER_TYPE_BUY_STOP:   price = N(Ask + dist); break;
      case ORDER_TYPE_SELL_STOP:  price = N(Bid - dist); break;
      case ORDER_TYPE_SELL_LIMIT: price = N(Bid + dist); break;
      default:                    price = N(Ask - dist); break; // BUY_LIMIT
     }
   double s = isBuy ? N(price - slD) : N(price + slD);
   double t = isBuy ? N(price + tpD) : N(price - tpD);
   sl = UseStopLoss   ? s : 0;
   tp = UseTakeProfit ? t : 0;
  }

// Trail existing pending orders; returns number of our pending orders (count_184)
int ManagePendingOrders()
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(!IsBuyPending(type) && !IsSellPending(type)) continue;
      count++;

      double cur = N(OrderGetDouble(ORDER_PRICE_OPEN));
      double price, sl, tp;
      PendingPrices(type, price, sl, tp);

      // Stop-buy / limit-sell follow price down, stop-sell / limit-buy follow price up
      bool moveDown = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_LIMIT);
      if(moveDown  && !(price < cur)) continue;
      if(!moveDown && !(price > cur)) continue;
      if(MinModifyStep > 0 && MathAbs(price - cur) < MinModifyStep * _Point) continue;

      if(!trade.OrderModify(tk, price, sl, tp, ORDER_TIME_GTC, 0))
         Print(EnumToString(type), " Modify Error ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription(),
               " OP: ", DoubleToString(price, _Digits), " SL: ", DoubleToString(sl, _Digits), " TP: ", DoubleToString(tp, _Digits),
               " Bid: ", DoubleToString(Bid, _Digits), " Ask: ", DoubleToString(Ask, _Digits));
     }
   return(count);
  }

bool PlacePending(const ENUM_ORDER_TYPE type, const double lots)
  {
   double price, sl, tp;
   PendingPrices(type, price, sl, tp);

   // Skip orders the account cannot margin (the broker would reject them anyway)
   ENUM_ORDER_TYPE mtype = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin = 0;
   if(OrderCalcMargin(mtype, _Symbol, lots, price, margin) && margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      Print("EA RoboFibo: not enough free margin for ", DoubleToString(lots, g_lotDigits), " lots");
      return(false);
     }

   bool ok = false;
   switch(type)
     {
      case ORDER_TYPE_BUY_STOP:   ok = trade.BuyStop(lots,   price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, TradeComment); break;
      case ORDER_TYPE_SELL_STOP:  ok = trade.SellStop(lots,  price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, TradeComment); break;
      case ORDER_TYPE_BUY_LIMIT:  ok = trade.BuyLimit(lots,  price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, TradeComment); break;
      case ORDER_TYPE_SELL_LIMIT: ok = trade.SellLimit(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, TradeComment); break;
      default: break;
     }
   if(!ok)
      Print(EnumToString(type), " Send Error ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription(),
            " LT: ", DoubleToString(lots, g_lotDigits), " OP: ", DoubleToString(price, _Digits),
            " SL: ", DoubleToString(sl, _Digits), " TP: ", DoubleToString(tp, _Digits),
            " Bid: ", DoubleToString(Bid, _Digits), " Ask: ", DoubleToString(Ask, _Digits));
   return(ok);
  }

//==================================================================
//  BASKET TAKE-PROFIT  (MoveTP / MoveTP2)
//==================================================================
void MoveTPSide(const ENUM_POSITION_TYPE type, const int tpPoints)
  {
   double avg, lots;
   if(!BasketAverage(type, avg, lots)) return;
   bool isBuy = (type == POSITION_TYPE_BUY);
   double tp = isBuy ? N(avg + tpPoints * _Point) : N(avg - tpPoints * _Point);

   // Price is already beyond the basket target: take it now instead of sending invalid modifies
   if((isBuy && Bid >= tp) || (!isBuy && Ask <= tp))
     {
      CloseSide(type, false);
      return;
     }
   // Too close for the broker's stop level: wait
   if(isBuy  && tp - Bid < stoplevel * _Point) return;
   if(!isBuy && Ask - tp < stoplevel * _Point) return;

   ulong tk;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectOurPosition(i, tk)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      if(MathAbs(PositionGetDouble(POSITION_TP) - tp) < _Point / 2) continue;
      if(!trade.PositionModify(tk, PositionGetDouble(POSITION_SL), tp))
         Print(Symbol(), ": TP modify failed #", tk, " ", trade.ResultRetcodeDescription());
     }
  }

void MoveTP()
  {
   int pts = (TakeProfitAll >= stoplevel) ? TakeProfitAll : stoplevel;  // MoveTP2 in the original used stoplevel
   if(pts <= 0) return;
   MoveTPSide(POSITION_TYPE_BUY,  pts);
   MoveTPSide(POSITION_TYPE_SELL, pts);
  }

//==================================================================
//  TRAILING  (MoveTrailingStop / MoveTrailingStop2)
//==================================================================
void MoveTrailingStop()
  {
   if(TrailingStop <= 0) return;
   int d = (TrailingStop >= stoplevel) ? TrailingStop : stoplevel;
   double avgB, lotsB, avgS, lotsS;
   bool hasB = BasketAverage(POSITION_TYPE_BUY,  avgB, lotsB);
   bool hasS = BasketAverage(POSITION_TYPE_SELL, avgS, lotsS);
   ulong tk;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectOurPosition(i, tk)) continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double oop = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  = N(PositionGetDouble(POSITION_SL));
      double tp  = PositionGetDouble(POSITION_TP);
      if(type == POSITION_TYPE_BUY && hasB)
        {
         double trig = N(Ask - TrailingStart * _Point);
         if(trig > N(oop + d * _Point) && trig > N(avgB + d * _Point))
           {
            double nsl = N(Bid - d * _Point);
            if(sl < nsl || sl == 0)
               if(trade.PositionModify(tk, nsl, tp)) Print(Symbol(), ": Trailing Buy modify ok");
           }
        }
      else if(type == POSITION_TYPE_SELL && hasS)
        {
         double trig = N(Bid + TrailingStart * _Point);
         if(trig < N(oop - d * _Point) && trig < N(avgS - d * _Point))
           {
            double nsl = N(Ask + d * _Point);
            if(sl > nsl || sl == 0)
               if(trade.PositionModify(tk, nsl, tp)) Print(Symbol(), ": Trailing Sell modify ok");
           }
        }
     }
  }

//==================================================================
//  VIRTUAL SL / TP / TRAILING
//==================================================================
void VirtualTrailing()
  {
   double avgB, lotsB, avgS, lotsS;
   BasketAverage(POSITION_TYPE_BUY,  avgB, lotsB);
   BasketAverage(POSITION_TYPE_SELL, avgS, lotsS);

   int b = 0, s = 0;
   ulong TicketB = 0, TicketS = 0, tk;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectOurPosition(i, tk)) continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double OOP = N(PositionGetDouble(POSITION_PRICE_OPEN));

      if(type == POSITION_TYPE_BUY)
        {
         if(VirtualStopLoss   && StopLoss   != 0 && Bid <= OOP - StopLoss * _Point)   { trade.PositionClose(tk, Slippage); continue; }
         if(VirtualTakeProfit && TakeProfit != 0 && Bid >= OOP + TakeProfit * _Point) { trade.PositionClose(tk, Slippage); continue; }
         b++;
         TicketB = tk;
         if(UseVirtualTrailing && VirtualTrailingStop > 0)
           {
            double SLB = N(Ask - VirtualTrailingStop * _Point);
            if(SLB > N(avgB + VirtualTrailingStart * _Point))
               if(SLB >= OOP + VirtualTrailingStart * _Point && (TrallB == 0 || TrallB + VirtualTrailingStep * _Point < SLB)) TrallB = SLB;
           }
        }
      else
        {
         if(VirtualStopLoss   && StopLoss   != 0 && Ask >= OOP + StopLoss * _Point)   { trade.PositionClose(tk, Slippage); continue; }
         if(VirtualTakeProfit && TakeProfit != 0 && Ask <= OOP - TakeProfit * _Point) { trade.PositionClose(tk, Slippage); continue; }
         s++;
         TicketS = tk;
         if(UseVirtualTrailing && VirtualTrailingStop > 0)
           {
            double SLS = N(Bid + VirtualTrailingStop * _Point);
            if(SLS < N(avgS - VirtualTrailingStart * _Point))
               if(SLS <= OOP - VirtualTrailingStart * _Point && (TrallS == 0 || TrallS - VirtualTrailingStep * _Point > SLS)) TrallS = SLS;
           }
        }
     }

   if(!UseVirtualTrailing) return;

   if(b != 0)
     {
      if(TrallB != 0)
        {
         DrawHline("SL Buy", TrallB, clrYellow, 1);
         if(Bid <= TrallB && PositionSelectByTicket(TicketB) && PositionGetDouble(POSITION_PROFIT) > 0)
            if(!trade.PositionClose(TicketB, Slippage)) Comment("Virtual Trailing Buy ", trade.ResultRetcode());
        }
     }
   else { TrallB = 0; ObjectDelete(0, OBJ_PREFIX + "SL Buy"); }

   if(s != 0)
     {
      if(TrallS != 0)
        {
         DrawHline("SL Sell", TrallS, clrYellow, 1);
         if(Ask >= TrallS && PositionSelectByTicket(TicketS) && PositionGetDouble(POSITION_PROFIT) > 0)
            if(!trade.PositionClose(TicketS, Slippage)) Comment("Virtual Trailing Sell ", trade.ResultRetcode());
        }
     }
   else { TrallS = 0; ObjectDelete(0, OBJ_PREFIX + "SL Sell"); }
  }

//==================================================================
//  NEWS FILTER (MT5 Economic Calendar)
//==================================================================
bool CurrencyWanted(const string cur)
  {
   if(cur == s1 || cur == s2) return(true);
   if(ForceALL && cur == "ALL") return(true);
   if(ForceUSD && cur == "USD") return(true);
   if(ForceCNY && cur == "CNY") return(true);
   if(ForceGBP && cur == "GBP") return(true);
   if(ForceJPY && cur == "JPY") return(true);
   if(ForceAUD && cur == "AUD") return(true);
   if(ForceCAD && cur == "CAD") return(true);
   if(ForceCHF && cur == "CHF") return(true);
   if(ForceEUR && cur == "EUR") return(true);
   if(ForceNZD && cur == "NZD") return(true);
   return(false);
  }

void UpdateNews()
  {
   if(!NewsFilter || MQLInfoInteger(MQL_TESTER)) return;   // the calendar is not available in the tester
   datetime now = TimeTradeServer();
   int period = MathMax(1, UpdateHour) * 3600;
   if(g_newsLastUpdate != 0 && now - g_newsLastUpdate < period) return;
   g_newsLastUpdate = now;

   MqlCalendarValue vals[];
   ResetLastError();
   if(CalendarValueHistory(vals, now - 2 * 86400, now + 8 * 86400) <= 0)
     {
      Print("EA RoboFibo: calendar request failed (", GetLastError(), "), retrying in 5 minutes");
      g_newsLastUpdate = now - period + 300;
      return;
     }

   ArrayResize(g_newsTime, 0);
   ArrayResize(g_newsImpact, 0);
   ArrayResize(g_newsTitle, 0);
   ArrayResize(g_newsCur, 0);

   int total = ArraySize(vals);
   for(int i = 0; i < total; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(vals[i].event_id, ev)) continue;
      int imp = (int)ev.importance;   // 0 none, 1 low, 2 moderate, 3 high
      if(imp < MinimumImpact) continue;
      MqlCalendarCountry c;
      if(!CalendarCountryById(ev.country_id, c)) continue;
      if(!CurrencyWanted(c.currency)) continue;

      int n = ArraySize(g_newsTime);
      ArrayResize(g_newsTime, n + 1);
      ArrayResize(g_newsImpact, n + 1);
      ArrayResize(g_newsTitle, n + 1);
      ArrayResize(g_newsCur, n + 1);
      g_newsTime[n]   = vals[i].time;
      g_newsImpact[n] = imp;
      g_newsTitle[n]  = ev.name;
      g_newsCur[n]    = c.currency;
     }
  }

// fills prevnews / nextnews (minutes) and the panel strings; true = trading blocked
bool NewsBlackout()
  {
   prevnews = 99999;
   nextnews = -1;
   title0 = ""; country0 = ""; date0 = "";
   titlex = ""; countryx = ""; datex = "";
   if(!NewsFilter) return(false);

   datetime now = TimeTradeServer();
   int prevI = -1, nextI = -1;
   int n = ArraySize(g_newsTime);
   for(int i = 0; i < n; i++)
     {
      if(g_newsTime[i] <= now)
        { if(prevI < 0 || g_newsTime[i] > g_newsTime[prevI]) prevI = i; }
      else
        { if(nextI < 0 || g_newsTime[i] < g_newsTime[nextI]) nextI = i; }
     }
   if(prevI >= 0)
     {
      prevnews = (long)(now - g_newsTime[prevI]) / 60;
      title0 = g_newsTitle[prevI]; country0 = g_newsCur[prevI]; date0 = TimeToString(g_newsTime[prevI]);
     }
   if(nextI >= 0)
     {
      nextnews = (long)(g_newsTime[nextI] - now) / 60;
      titlex = g_newsTitle[nextI]; countryx = g_newsCur[nextI]; datex = TimeToString(g_newsTime[nextI]);
     }
   return(prevnews < EnableMinAfterNews || (nextnews >= 0 && nextnews <= DisableMinBeforeNews));
  }

//==================================================================
//  MAIN
//==================================================================
void OnTick()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   Ask = tick.ask;
   Bid = tick.bid;
   stoplevel      = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   stoplevelPrice = N(stoplevel * _Point);

   Process();
   ChartComment();
  }

void Process()
  {
   CalcFibo();
   if(ArraySize(g_commId) > 0 && PositionsTotal() == 0) { ArrayResize(g_commId, 0); ArrayResize(g_commVal, 0); }

   int nBuy  = CountTradesBuy();
   int nSell = CountTradesSell();
   if(nBuy  == 0) CloseSignal  = false;
   if(nSell == 0) CloseSignal2 = false;

   TotalProfitbuy();
   TotalProfitsell();

   // ---- money targets per basket
   double Ld_196 = UseMM ? NormalizeDouble(BaseLot(), g_lotDigits) : FixedLots;
   TPsell = AutoTargetMoney   ? Ld_196 * TargetMoneyFactor * nSell * LotsExponent : TargetMoney;
   TPbuy  = AutoTargetMoney   ? Ld_196 * TargetMoneyFactor * nBuy  * LotsExponent : TargetMoney;
   SLsell = AutoStopLossMoney ? Ld_196 * StoplossFactor    * nSell * LotsExponent : StoplossMoney;
   SLbuy  = AutoStopLossMoney ? Ld_196 * StoplossFactor    * nBuy  * LotsExponent : StoplossMoney;

   if((TPbuy > 0 && totalProfits >= TPbuy) || (SLbuy > 0 && totalProfits <= -SLbuy)) CloseSignal = true;
   if(CloseSignal) OpenOrdClose();
   if((TPsell > 0 && totalProfits2 >= TPsell) || (SLsell > 0 && totalProfits2 <= -SLsell)) CloseSignal2 = true;
   if(CloseSignal2) OpenOrdClose2();

   CheckDrawdownGuard();

   if(UseTakeProfitAll) MoveTP();
   if(UseTrailing)      MoveTrailingStop();
   if(UseVirtualTrailing || VirtualStopLoss || VirtualTakeProfit) VirtualTrailing();

   nBuy  = CountTradesBuy();
   nSell = CountTradesSell();

   double Pipstep2 = NormalizeDouble(Pipstep * MathPow(PipstepExponent, nBuy),  0);
   double Pipstep3 = NormalizeDouble(Pipstep * MathPow(PipstepExponent, nSell), 0);
   double lastsell = FindLastPrice(POSITION_TYPE_SELL);
   double lastbuy  = FindLastPrice(POSITION_TYPE_BUY);

   double highlow  = iHigh(_Symbol, _Period, 0) - iLow(_Symbol, _Period, 0);
   double highlow2 = iHigh(_Symbol, _Period, 1) - iLow(_Symbol, _Period, 1);

   // ---- signal
   close1 = iClose(_Symbol, IClose, 1);
   close2 = iClose(_Symbol, IClose, 2);
   double rsiBuf[], maBuf[];
   if(CopyBuffer(hRSI, 0, 0, 2, rsiBuf) < 2) return;   // [0] = bar 1, [1] = bar 0
   if(CopyBuffer(hMA,  0, 1, 1, maBuf)  < 1) return;
   rsia = rsiBuf[1];
   rsib = rsiBuf[0];
   ma   = maBuf[0];

   if(close1 > close2)      sign = "BUY Signal";
   else if(close1 < close2) sign = "SELL Signal";
   else                     sign = "No Signal";

   if(rsia > 70.0 || rsib > 70.0)      sign2 = "RSI is OVERBOUGHT";
   else if(rsia < 30.0 || rsib < 30.0) sign2 = "RSI is OVERSOLD";
   else                                sign2 = "RSI is Ranging";

   if(Bid > ma)      sign3 = "BULLISH";
   else if(Bid < ma) sign3 = "BEARISH";
   else              sign3 = "RANGING";

   // ---- fibo zone of the last BarsBack bars
   int lowest_bar  = iLowest(_Symbol, _Period, MODE_LOW,  BarsBack, StartBar);
   int highest_bar = iHighest(_Symbol, _Period, MODE_HIGH, BarsBack, StartBar);
   if(lowest_bar < 0 || highest_bar < 0) return;
   double HighValue = iHigh(_Symbol, _Period, highest_bar);
   double LowValue  = iLow(_Symbol, _Period, lowest_bar);
   double range     = HighValue - LowValue;
   double pricein0  = (LowFibo  / 100.0) * range + LowValue;
   double pricein6  = (HighFibo / 100.0) * range + LowValue;

   // ---- spread + commission
   EstimateCommission();
   for(int k = 0; k < SPREAD_HIST - 1; k++) g_spread[k] = g_spread[k + 1];
   g_spread[SPREAD_HIST - 1] = Ask - Bid;
   if(g_spreadCount < SPREAD_HIST) g_spreadCount++;
   double sum = 0;
   for(int k = 0; k < g_spreadCount; k++) sum += g_spread[SPREAD_HIST - 1 - k];
   double avgSpread = sum / g_spreadCount;
   double Ld_164 = NormalizeDouble(avgSpread + g_commPrice, _Digits + 1);

   // ---- grid permission (Maxtrade / Maxtrade2 in the original, recomputed every tick)
   bool calmBars = (highlow <= g_candleRange && highlow2 <= g_candleRange);
   int Maxtrade  = nBuy  - 100;
   int Maxtrade2 = nSell - 100;
   if(calmBars && nBuy  > 0 && nBuy  < MaxOrderBuy  && (lastbuy - Ask  >= (PendingDistance + Pipstep2) * _Point)) Maxtrade  = nBuy;
   if(calmBars && nSell > 0 && nSell < MaxOrderSell && (Bid - lastsell >= (PendingDistance + Pipstep3) * _Point)) Maxtrade2 = nSell;

   bool rsiNotOB = (rsia < 70.0 && rsib < 70.0);
   bool rsiNotOS = (rsia > 30.0 && rsib > 30.0);

   // Li_180: +1 / -1 selects the order type in the placement switch below (the "sell" block overrides the "buy" block)
   int Li_180 = 0;
   switch(TradingMode)
     {
      case PendingLimitFollow:
         if(nBuy == 0 && close1 > close2 && Ask > ma && Ask > pricein6 && rsiNotOB) Li_180 = -1;
         else if(nBuy == Maxtrade && close1 > close2 && Ask > ma && rsiNotOB)      Li_180 = -1;
         if(nSell == 0 && close1 < close2 && Bid < ma && Bid < pricein0 && rsiNotOS) Li_180 = 1;
         else if(nSell == Maxtrade2 && close1 < close2 && Bid < ma && rsiNotOS)      Li_180 = 1;
         break;

      case PendingLimitReverse:
         if(nBuy == 0 && close1 > close2 && Ask > ma && Ask < pricein0 && rsiNotOB)        Li_180 = 1;
         else if(nBuy == Maxtrade && close1 > close2 && Ask > ma && Ask < pricein0 && rsiNotOB) Li_180 = 1;
         if(nSell == 0 && close1 < close2 && Bid < ma && Bid > pricein6 && rsiNotOS) Li_180 = -1;
         else if(nSell == Maxtrade2 && close1 < close2 && Bid < ma && rsiNotOS)      Li_180 = -1;
         break;

      case PendingStopFollow:
         if(nBuy == 0)             Li_180 = -1;
         else if(nBuy == Maxtrade) Li_180 = -1;
         if(nSell == 0 && close1 < close2 && Bid < ma && Bid < pricein0 && rsiNotOS) Li_180 = 1;
         else if(nSell == Maxtrade2 && close1 < close2 && Bid < ma && rsiNotOS)      Li_180 = 1;
         break;

      case PendingStopReverse:
         if(nBuy == 0 && Ask < pricein0) Li_180 = 1;
         else if(nBuy == Maxtrade)       Li_180 = 1;
         if(nSell == 0 && Bid > pricein6) Li_180 = -1;
         else if(nSell == Maxtrade2)      Li_180 = -1;
         break;
     }

   // ---- trail existing pending orders
   int count_184 = ManagePendingOrders();

   // ---- news filter
   UpdateNews();
   bool blocked = NewsBlackout();
   status1 = blocked ? "News Time Trade Is Disabled" : "Trade Is Active";
   if(blocked)
     {
      if(DeletePendingOnNews && count_184 > 0) DeleteAllPending();
      return;
     }
   if(g_haltDay == DayOfYearNow()) { status1 = "Paused: drawdown guard hit today"; return; }

   // ---- new pending order (only when none is pending)
   if(count_184 != 0 || Li_180 == 0 || Ld_164 > g_maxSpread || !f0_4()) return;

   double base = BaseLot();
   double lotB = NormalizeLot(base * MathPow(LotsExponent, nBuy));
   double lotS = NormalizeLot(base * MathPow(LotsExponent, nSell));

   switch(TradingMode)
     {
      case PendingLimitFollow:
         if(Li_180 < 0) PlacePending(ORDER_TYPE_BUY_LIMIT,  lotB);
         else           PlacePending(ORDER_TYPE_SELL_LIMIT, lotS);
         break;
      case PendingLimitReverse:
         if(Li_180 < 0) PlacePending(ORDER_TYPE_SELL_LIMIT, lotS);
         else           PlacePending(ORDER_TYPE_BUY_LIMIT,  lotB);
         break;
      case PendingStopFollow:
         if(Li_180 < 0) PlacePending(ORDER_TYPE_BUY_STOP,  lotB);
         else           PlacePending(ORDER_TYPE_SELL_STOP, lotS);
         break;
      case PendingStopReverse:
         if(Li_180 < 0) PlacePending(ORDER_TYPE_SELL_STOP, lotS);
         else           PlacePending(ORDER_TYPE_BUY_STOP,  lotB);
         break;
     }
  }

//==================================================================
//  CHART OBJECTS
//==================================================================
void DrawVerticalLine(const string name, const int bar, const color clr)
  {
   string n = OBJ_PREFIX + name;
   datetime t = iTime(_Symbol, _Period, bar);
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_VLINE, 0, t, 0);
      ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, n, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, n, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
     }
   else
      ObjectMove(0, n, 0, t, 0);
  }

void DrawHline(const string name, const double price, const color clr, const int width)
  {
   string n = OBJ_PREFIX + name;
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, n, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, n, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
     }
   else
      ObjectMove(0, n, 0, 0, price);
  }

void CalcFibo()
  {
   int lowest_bar  = iLowest(_Symbol, _Period, MODE_LOW,  BarsBack, StartBar);
   int highest_bar = iHighest(_Symbol, _Period, MODE_HIGH, BarsBack, StartBar);
   if(lowest_bar < 0 || highest_bar < 0) return;
   double HighValue = iHigh(_Symbol, _Period, highest_bar);
   double LowValue  = iLow(_Symbol, _Period, lowest_bar);
   datetime tHigh   = iTime(_Symbol, _Period, highest_bar);
   datetime tLow    = iTime(_Symbol, _Period, lowest_bar);

   DrawVerticalLine("v_u_hl", highest_bar, VerticalLinesColor);
   DrawVerticalLine("v_l_hl", lowest_bar,  VerticalLinesColor);

   string tr = OBJ_PREFIX + "trend_hl";
   if(ObjectFind(0, tr) < 0)
     {
      ObjectCreate(0, tr, OBJ_TREND, 0, tHigh, HighValue, tLow, LowValue);
      ObjectSetInteger(0, tr, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, tr, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, tr, OBJPROP_SELECTABLE, false);
     }
   ObjectMove(0, tr, 0, tHigh, HighValue);
   ObjectMove(0, tr, 1, tLow,  LowValue);

   string fb = OBJ_PREFIX + "Fibo_hl";
   if(ObjectFind(0, fb) < 0)
     {
      ObjectCreate(0, fb, OBJ_FIBO, 0, tHigh, HighValue, tLow, LowValue);
      ObjectSetInteger(0, fb, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, fb, OBJPROP_RAY_RIGHT, true);
      double lv[7]  = {0.0, 0.236, 0.382, 0.5, 0.618, 0.764, 1.0};   // Fibo_Level_0 .. Fibo_Level_6
      string txt[7] = {"SWING LOW (0.0) - %$", "BREAKOUT AREA (23.6) - %$", "CRITICAL AREA (38.2) - %$",
                       "CRITICAL AREA (50.0) - %$", "CRITICAL AREA (61.8) - %$", "BREAKOUT AREA (76.4) - %$",
                       "SWING HIGH (100.0) - %$"};
      ObjectSetInteger(0, fb, OBJPROP_LEVELS, 7);
      for(int i = 0; i < 7; i++)
        {
         ObjectSetDouble(0, fb, OBJPROP_LEVELVALUE, i, lv[i]);
         ObjectSetString(0, fb, OBJPROP_LEVELTEXT, i, txt[i]);
         ObjectSetInteger(0, fb, OBJPROP_LEVELCOLOR, i, FiboLinesColors);
        }
     }
   ObjectMove(0, fb, 0, tHigh, HighValue);
   ObjectMove(0, fb, 1, tLow,  LowValue);
  }

//==================================================================
//  INFO PANEL
//==================================================================
#define PANEL_W 300

void PanelRect(const string name, const int y, const int h, const color bg)
  {
   string n = OBJ_PREFIX + name;
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, n, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, n, OBJPROP_CORNER, Side == right ? CORNER_RIGHT_UPPER : CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, Side == right ? PANEL_W + 5 : 5);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, PANEL_W);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_COLOR, bg);
  }

void PanelLabel(const string name, const string text, const int y)
  {
   string n = OBJ_PREFIX + name;
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetString(0, n, OBJPROP_FONT, "Tahoma");
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 10);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
     }
   bool r = (Side == right);
   ObjectSetInteger(0, n, OBJPROP_CORNER, r ? CORNER_RIGHT_UPPER : CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, r ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, 15);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_COLOR, Textcolor);
   ObjectSetString(0, n, OBJPROP_TEXT, text);
  }

void ChartComment()
  {
   PanelRect("Background",   10,  30, Backgroundcolor);
   PanelRect("Background_2", 40,  85, Backgroundcolor2);
   PanelRect("Background_3", 125, 125, Backgroundcolor3);
   PanelRect("Background_4", 250, 135, Backgroundcolor4);
   PanelRect("Background_5", 385, 40, Backgroundcolor5);

   PanelLabel("Info_1",  "Expert Advisor Robofibo v.11 (MQL5)", 17);
   PanelLabel("Info_2",  "Name = " + AccountInfoString(ACCOUNT_NAME), 45);
   PanelLabel("Info_3",  "Broker =  " + AccountInfoString(ACCOUNT_COMPANY), 60);
   PanelLabel("Info_4",  "Account Balance = " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2), 75);
   PanelLabel("Info_5",  "Account Equity = " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), 90);
   PanelLabel("Info_6",  "Day Profit = " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE) - startBalanceD1(), 2), 105);
   PanelLabel("Info_7",  "Open ALL Positions = " + IntegerToString(PositionsTotal()), 130);
   PanelLabel("Info_8",  _Symbol + " EA Orders = " + IntegerToString(CountTradesBuy() + CountTradesSell()), 145);
   PanelLabel("Info_9",  "Open Buy  = " + IntegerToString(CountTradesBuy()), 160);
   PanelLabel("Info_10", "Open Sell = " + IntegerToString(CountTradesSell()), 175);
   PanelLabel("Info_11", "Signal  = " + sign, 200);
   PanelLabel("Info_12", "RSI = " + sign2, 215);
   PanelLabel("Info_13", "Trend = " + sign3, 230);
   string np = (NewsFilter && MQLInfoInteger(MQL_TESTER)) ? "News filter: n/a in tester" : "Last news: " + date0;
   PanelLabel("Info_14", np, 255);
   PanelLabel("Info_15", title0 + " " + country0, 270);
   PanelLabel("Info_16", (title0 == "" ? "-" : IntegerToString(prevnews) + " Minutes ago"), 285);
   PanelLabel("Info_17", "Next news: " + datex, 310);
   PanelLabel("Info_18", titlex + " " + countryx, 325);
   PanelLabel("Info_19", (titlex == "" ? "-" : "In " + IntegerToString(nextnews) + " Minutes"), 340);
   PanelLabel("Info_20", status1, 365);
   PanelLabel("Info_21", "Buy Profit = "  + DoubleToString(totalProfits, 2), 390);
   PanelLabel("Info_22", "Sell Profit = " + DoubleToString(totalProfits2, 2), 405);
  }
//+------------------------------------------------------------------+
