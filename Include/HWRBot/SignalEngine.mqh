//+------------------------------------------------------------------+
//|                                                 SignalEngine.mqh  |
//|        High Win-Rate Bot - Trend-Pullback signal generator       |
//+------------------------------------------------------------------+
//| Strategy logic (high win-rate, "trade with the trend"):          |
//|                                                                  |
//|  1. TREND FILTER: price relative to a slow EMA (e.g. EMA200)     |
//|     decides the only direction we are allowed to trade.          |
//|        price > EMA_slow  -> longs only                           |
//|        price < EMA_slow  -> shorts only                          |
//|                                                                  |
//|  2. PULLBACK: a faster EMA (e.g. EMA50) keeps us trading the     |
//|     dominant swing, and RSI must dip into a "value zone" on the  |
//|     pullback (oversold-ish in an uptrend / overbought-ish in a   |
//|     downtrend) rather than chasing extended moves.               |
//|                                                                  |
//|  3. MOMENTUM CONFIRMATION: RSI must turn back up (long) / down   |
//|     (short) on the most recent closed bar -> entry trigger.      |
//|                                                                  |
//|  ATR is exposed so the EA can place structure-aware SL/TP.       |
//+------------------------------------------------------------------+
#property copyright "HighWinRateBot"
#property strict

enum ENUM_SIGNAL
  {
   SIGNAL_NONE = 0,
   SIGNAL_BUY  = 1,
   SIGNAL_SELL = -1
  };

//+------------------------------------------------------------------+
class CSignalEngine
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;

   //--- indicator handles
   int               m_hEmaFast;
   int               m_hEmaSlow;
   int               m_hRsi;
   int               m_hAtr;

   //--- parameters
   int               m_emaFastPeriod;
   int               m_emaSlowPeriod;
   int               m_rsiPeriod;
   double            m_rsiBuyZone;   // pullback threshold for longs  (e.g. 40)
   double            m_rsiSellZone;  // pullback threshold for shorts (e.g. 60)
   int               m_atrPeriod;

   //--- buffer helper
   bool              CopyOne(const int handle,const int shift,double &value);

public:
                     CSignalEngine(void);
                    ~CSignalEngine(void);
   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,
                          const int emaFast,const int emaSlow,
                          const int rsiPeriod,const double rsiBuyZone,
                          const double rsiSellZone,const int atrPeriod);
   void              Deinit(void);

   ENUM_SIGNAL       CheckSignal(void);
   double            GetATR(const int shift=1);
  };

//+------------------------------------------------------------------+
CSignalEngine::CSignalEngine(void)
  {
   m_hEmaFast=INVALID_HANDLE;
   m_hEmaSlow=INVALID_HANDLE;
   m_hRsi=INVALID_HANDLE;
   m_hAtr=INVALID_HANDLE;
  }

CSignalEngine::~CSignalEngine(void) { Deinit(); }

//+------------------------------------------------------------------+
bool CSignalEngine::Init(const string symbol,const ENUM_TIMEFRAMES tf,
                         const int emaFast,const int emaSlow,
                         const int rsiPeriod,const double rsiBuyZone,
                         const double rsiSellZone,const int atrPeriod)
  {
   m_symbol        = symbol;
   m_tf            = tf;
   m_emaFastPeriod = emaFast;
   m_emaSlowPeriod = emaSlow;
   m_rsiPeriod     = rsiPeriod;
   m_rsiBuyZone    = rsiBuyZone;
   m_rsiSellZone   = rsiSellZone;
   m_atrPeriod     = atrPeriod;

   m_hEmaFast = iMA(m_symbol,m_tf,m_emaFastPeriod,0,MODE_EMA,PRICE_CLOSE);
   m_hEmaSlow = iMA(m_symbol,m_tf,m_emaSlowPeriod,0,MODE_EMA,PRICE_CLOSE);
   m_hRsi     = iRSI(m_symbol,m_tf,m_rsiPeriod,PRICE_CLOSE);
   m_hAtr     = iATR(m_symbol,m_tf,m_atrPeriod);

   if(m_hEmaFast==INVALID_HANDLE || m_hEmaSlow==INVALID_HANDLE ||
      m_hRsi==INVALID_HANDLE     || m_hAtr==INVALID_HANDLE)
     {
      Print("SignalEngine: failed to create one or more indicator handles");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
void CSignalEngine::Deinit(void)
  {
   if(m_hEmaFast!=INVALID_HANDLE){ IndicatorRelease(m_hEmaFast); m_hEmaFast=INVALID_HANDLE; }
   if(m_hEmaSlow!=INVALID_HANDLE){ IndicatorRelease(m_hEmaSlow); m_hEmaSlow=INVALID_HANDLE; }
   if(m_hRsi!=INVALID_HANDLE){ IndicatorRelease(m_hRsi); m_hRsi=INVALID_HANDLE; }
   if(m_hAtr!=INVALID_HANDLE){ IndicatorRelease(m_hAtr); m_hAtr=INVALID_HANDLE; }
  }

//+------------------------------------------------------------------+
bool CSignalEngine::CopyOne(const int handle,const int shift,double &value)
  {
   double buf[];
   if(CopyBuffer(handle,0,shift,1,buf)!=1)
      return false;
   value=buf[0];
   return true;
  }

//+------------------------------------------------------------------+
double CSignalEngine::GetATR(const int shift)
  {
   double v=0.0;
   if(!CopyOne(m_hAtr,shift,v))
      return 0.0;
   return v;
  }

//+------------------------------------------------------------------+
//| Evaluate the most recently CLOSED bar (shift 1) for a setup.     |
//+------------------------------------------------------------------+
ENUM_SIGNAL CSignalEngine::CheckSignal(void)
  {
   double emaFast,emaSlow,rsiNow,rsiPrev,closeNow;

   if(!CopyOne(m_hEmaFast,1,emaFast)) return SIGNAL_NONE;
   if(!CopyOne(m_hEmaSlow,1,emaSlow)) return SIGNAL_NONE;
   if(!CopyOne(m_hRsi,1,rsiNow))      return SIGNAL_NONE;
   if(!CopyOne(m_hRsi,2,rsiPrev))     return SIGNAL_NONE;

   closeNow=iClose(m_symbol,m_tf,1);
   if(closeNow<=0.0) return SIGNAL_NONE;

   //--- LONG setup: established uptrend + healthy pullback + momentum turn up
   bool upTrend     = (closeNow>emaSlow) && (emaFast>emaSlow);
   bool buyPullback = (rsiPrev<=m_rsiBuyZone);          // dipped into value
   bool buyTrigger  = (rsiNow>rsiPrev);                 // momentum turning up
   if(upTrend && buyPullback && buyTrigger)
      return SIGNAL_BUY;

   //--- SHORT setup: established downtrend + pullback + momentum turn down
   bool downTrend    = (closeNow<emaSlow) && (emaFast<emaSlow);
   bool sellPullback = (rsiPrev>=m_rsiSellZone);
   bool sellTrigger  = (rsiNow<rsiPrev);
   if(downTrend && sellPullback && sellTrigger)
      return SIGNAL_SELL;

   return SIGNAL_NONE;
  }
//+------------------------------------------------------------------+
