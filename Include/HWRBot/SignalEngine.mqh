//+------------------------------------------------------------------+
//|                                                 SignalEngine.mqh  |
//|        High Win-Rate Bot - Trend-Pullback signal generator       |
//+------------------------------------------------------------------+
//| Strategy logic (high win-rate, "trade with the trend"):          |
//|                                                                  |
//|  0. HTF TREND (optional): a higher-timeframe EMA must agree with |
//|     the trade direction. Top-down bias is how desks avoid        |
//|     counter-trend traps.                                         |
//|                                                                  |
//|  1. TREND FILTER: price vs. a slow EMA on the working TF decides |
//|     the only direction we are allowed to trade.                  |
//|                                                                  |
//|  2. PULLBACK: a faster EMA keeps us on the dominant swing, and   |
//|     RSI must dip into a "value zone" on the pullback rather than |
//|     chasing an extended move.                                    |
//|                                                                  |
//|  3. MOMENTUM CONFIRMATION: RSI must turn back in the trend       |
//|     direction on the most recent closed bar -> entry trigger.    |
//|                                                                  |
//|  ATR is exposed so the EA can size structure-aware SL/TP and     |
//|  apply a volatility floor.                                       |
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
   ENUM_TIMEFRAMES   m_htf;

   //--- indicator handles
   int               m_hEmaFast;
   int               m_hEmaSlow;
   int               m_hEmaHtf;
   int               m_hRsi;
   int               m_hAtr;

   //--- parameters
   int               m_emaFastPeriod;
   int               m_emaSlowPeriod;
   int               m_emaHtfPeriod;
   int               m_rsiPeriod;
   double            m_rsiBuyZone;
   double            m_rsiSellZone;
   int               m_atrPeriod;
   bool              m_useHtf;

   bool              CopyOne(const int handle,const int shift,double &value);

public:
                     CSignalEngine(void);
                    ~CSignalEngine(void);
   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,
                          const int emaFast,const int emaSlow,
                          const int rsiPeriod,const double rsiBuyZone,
                          const double rsiSellZone,const int atrPeriod,
                          const bool useHtf,const ENUM_TIMEFRAMES htf,const int emaHtfPeriod);
   void              Deinit(void);

   ENUM_SIGNAL       CheckSignal(void);
   double            GetATR(const int shift=1);
  };

//+------------------------------------------------------------------+
CSignalEngine::CSignalEngine(void)
  {
   m_hEmaFast=INVALID_HANDLE; m_hEmaSlow=INVALID_HANDLE; m_hEmaHtf=INVALID_HANDLE;
   m_hRsi=INVALID_HANDLE;     m_hAtr=INVALID_HANDLE;     m_useHtf=false;
  }

CSignalEngine::~CSignalEngine(void) { Deinit(); }

//+------------------------------------------------------------------+
bool CSignalEngine::Init(const string symbol,const ENUM_TIMEFRAMES tf,
                         const int emaFast,const int emaSlow,
                         const int rsiPeriod,const double rsiBuyZone,
                         const double rsiSellZone,const int atrPeriod,
                         const bool useHtf,const ENUM_TIMEFRAMES htf,const int emaHtfPeriod)
  {
   m_symbol        = symbol;
   m_tf            = tf;
   m_htf           = htf;
   m_emaFastPeriod = emaFast;
   m_emaSlowPeriod = emaSlow;
   m_emaHtfPeriod  = emaHtfPeriod;
   m_rsiPeriod     = rsiPeriod;
   m_rsiBuyZone    = rsiBuyZone;
   m_rsiSellZone   = rsiSellZone;
   m_atrPeriod     = atrPeriod;
   m_useHtf        = useHtf;

   m_hEmaFast = iMA(m_symbol,m_tf,m_emaFastPeriod,0,MODE_EMA,PRICE_CLOSE);
   m_hEmaSlow = iMA(m_symbol,m_tf,m_emaSlowPeriod,0,MODE_EMA,PRICE_CLOSE);
   m_hRsi     = iRSI(m_symbol,m_tf,m_rsiPeriod,PRICE_CLOSE);
   m_hAtr     = iATR(m_symbol,m_tf,m_atrPeriod);
   if(m_useHtf)
      m_hEmaHtf = iMA(m_symbol,m_htf,m_emaHtfPeriod,0,MODE_EMA,PRICE_CLOSE);

   if(m_hEmaFast==INVALID_HANDLE || m_hEmaSlow==INVALID_HANDLE ||
      m_hRsi==INVALID_HANDLE     || m_hAtr==INVALID_HANDLE     ||
      (m_useHtf && m_hEmaHtf==INVALID_HANDLE))
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
   if(m_hEmaHtf!=INVALID_HANDLE){ IndicatorRelease(m_hEmaHtf); m_hEmaHtf=INVALID_HANDLE; }
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

   //--- higher-timeframe bias (optional)
   bool htfBull=true, htfBear=true;
   if(m_useHtf)
     {
      double emaHtf,closeHtf;
      if(!CopyOne(m_hEmaHtf,1,emaHtf)) return SIGNAL_NONE;
      closeHtf=iClose(m_symbol,m_htf,1);
      if(closeHtf<=0.0) return SIGNAL_NONE;
      htfBull=(closeHtf>emaHtf);
      htfBear=(closeHtf<emaHtf);
     }

   //--- LONG setup
   bool upTrend     = (closeNow>emaSlow) && (emaFast>emaSlow);
   bool buyPullback = (rsiPrev<=m_rsiBuyZone);
   bool buyTrigger  = (rsiNow>rsiPrev);
   if(htfBull && upTrend && buyPullback && buyTrigger)
      return SIGNAL_BUY;

   //--- SHORT setup
   bool downTrend    = (closeNow<emaSlow) && (emaFast<emaSlow);
   bool sellPullback = (rsiPrev>=m_rsiSellZone);
   bool sellTrigger  = (rsiNow<rsiPrev);
   if(htfBear && downTrend && sellPullback && sellTrigger)
      return SIGNAL_SELL;

   return SIGNAL_NONE;
  }
//+------------------------------------------------------------------+
