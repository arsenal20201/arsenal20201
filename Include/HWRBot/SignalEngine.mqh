//+------------------------------------------------------------------+
//|                                                 SignalEngine.mqh  |
//|     High Win-Rate Bot v2 - Trend-Pullback signal generator       |
//+------------------------------------------------------------------+
//| v2 entry logic (professional rework to cut false / chop trades   |
//| and premature stop-outs):                                        |
//|                                                                  |
//|  0. HTF TREND (optional): higher-timeframe EMA must agree.       |
//|  1. TREND: price vs slow EMA + fast/slow EMA stack, and the slow |
//|     EMA must be sloping in the trade direction.                  |
//|  2. STRENGTH: ADX >= threshold and the correct DI dominates ->   |
//|     no trading in chop.                                          |
//|  3. PULLBACK TO VALUE: within a lookback price must have tagged  |
//|     the fast-EMA zone AND RSI must have dipped into value.       |
//|  4. NOT OVEREXTENDED: close within N*ATR of the fast EMA.        |
//|  5. CONFIRMATION: a candle closing back through the fast EMA in  |
//|     the trade direction, with RSI momentum turning.             |
//|                                                                  |
//|  GetStopPrice() returns a structure-based stop (beyond the swing |
//|  +ATR buffer, clamped to min/max ATR distance).                  |
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
   int               m_hAdx;

   //--- parameters
   int               m_emaFastPeriod;
   int               m_emaSlowPeriod;
   int               m_emaHtfPeriod;
   int               m_rsiPeriod;
   double            m_rsiBuyZone;
   double            m_rsiSellZone;
   int               m_atrPeriod;
   bool              m_useHtf;
   bool              m_useAdx;
   int               m_adxPeriod;
   double            m_adxMin;
   bool              m_useSlope;
   int               m_slopeLen;
   int               m_pullLookback;
   double            m_pullTolAtr;
   bool              m_confirmBar;
   double            m_maxExtAtr;
   //--- stop config
   bool              m_useSwingStop;
   int               m_swingLook;
   double            m_stopBufAtr;
   double            m_atrSlMult;
   double            m_maxStopAtr;

   //--- helpers
   bool              CopyOne(const int handle,const int buf,const int shift,double &value);
   double            LowestLow(const int start,const int count);
   double            HighestHigh(const int start,const int count);
   double            LowestRSI(const int count);
   double            HighestRSI(const int count);

public:
                     CSignalEngine(void);
                    ~CSignalEngine(void);
   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,
                          const int emaFast,const int emaSlow,
                          const int rsiPeriod,const double rsiBuyZone,const double rsiSellZone,
                          const int atrPeriod,
                          const bool useHtf,const ENUM_TIMEFRAMES htf,const int emaHtfPeriod,
                          const bool useAdx,const int adxPeriod,const double adxMin,
                          const bool useSlope,const int slopeLen,
                          const int pullLookback,const double pullTolAtr,
                          const bool confirmBar,const double maxExtAtr,
                          const bool useSwingStop,const int swingLook,const double stopBufAtr,
                          const double atrSlMult,const double maxStopAtr);
   void              Deinit(void);

   ENUM_SIGNAL       CheckSignal(void);
   double            GetATR(const int shift=1);
   double            GetStopPrice(const int direction,const double entry,const double atr);
  };

//+------------------------------------------------------------------+
CSignalEngine::CSignalEngine(void)
  {
   m_hEmaFast=INVALID_HANDLE; m_hEmaSlow=INVALID_HANDLE; m_hEmaHtf=INVALID_HANDLE;
   m_hRsi=INVALID_HANDLE; m_hAtr=INVALID_HANDLE; m_hAdx=INVALID_HANDLE;
   m_useHtf=false; m_useAdx=true; m_useSlope=true;
  }

CSignalEngine::~CSignalEngine(void) { Deinit(); }

//+------------------------------------------------------------------+
bool CSignalEngine::Init(const string symbol,const ENUM_TIMEFRAMES tf,
                         const int emaFast,const int emaSlow,
                         const int rsiPeriod,const double rsiBuyZone,const double rsiSellZone,
                         const int atrPeriod,
                         const bool useHtf,const ENUM_TIMEFRAMES htf,const int emaHtfPeriod,
                         const bool useAdx,const int adxPeriod,const double adxMin,
                         const bool useSlope,const int slopeLen,
                         const int pullLookback,const double pullTolAtr,
                         const bool confirmBar,const double maxExtAtr,
                         const bool useSwingStop,const int swingLook,const double stopBufAtr,
                         const double atrSlMult,const double maxStopAtr)
  {
   m_symbol=symbol; m_tf=tf; m_htf=htf;
   m_emaFastPeriod=emaFast; m_emaSlowPeriod=emaSlow; m_emaHtfPeriod=emaHtfPeriod;
   m_rsiPeriod=rsiPeriod; m_rsiBuyZone=rsiBuyZone; m_rsiSellZone=rsiSellZone;
   m_atrPeriod=atrPeriod;
   m_useHtf=useHtf;
   m_useAdx=useAdx; m_adxPeriod=adxPeriod; m_adxMin=adxMin;
   m_useSlope=useSlope; m_slopeLen=slopeLen;
   m_pullLookback=pullLookback; m_pullTolAtr=pullTolAtr;
   m_confirmBar=confirmBar; m_maxExtAtr=maxExtAtr;
   m_useSwingStop=useSwingStop; m_swingLook=swingLook; m_stopBufAtr=stopBufAtr;
   m_atrSlMult=atrSlMult; m_maxStopAtr=maxStopAtr;

   m_hEmaFast = iMA(m_symbol,m_tf,m_emaFastPeriod,0,MODE_EMA,PRICE_CLOSE);
   m_hEmaSlow = iMA(m_symbol,m_tf,m_emaSlowPeriod,0,MODE_EMA,PRICE_CLOSE);
   m_hRsi     = iRSI(m_symbol,m_tf,m_rsiPeriod,PRICE_CLOSE);
   m_hAtr     = iATR(m_symbol,m_tf,m_atrPeriod);
   m_hAdx     = iADX(m_symbol,m_tf,m_adxPeriod);
   if(m_useHtf)
      m_hEmaHtf = iMA(m_symbol,m_htf,m_emaHtfPeriod,0,MODE_EMA,PRICE_CLOSE);

   if(m_hEmaFast==INVALID_HANDLE || m_hEmaSlow==INVALID_HANDLE ||
      m_hRsi==INVALID_HANDLE     || m_hAtr==INVALID_HANDLE     ||
      m_hAdx==INVALID_HANDLE     || (m_useHtf && m_hEmaHtf==INVALID_HANDLE))
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
   if(m_hAdx!=INVALID_HANDLE){ IndicatorRelease(m_hAdx); m_hAdx=INVALID_HANDLE; }
  }

//+------------------------------------------------------------------+
bool CSignalEngine::CopyOne(const int handle,const int buf,const int shift,double &value)
  {
   double b[];
   if(CopyBuffer(handle,buf,shift,1,b)!=1)
      return false;
   value=b[0];
   return true;
  }

//+------------------------------------------------------------------+
double CSignalEngine::LowestLow(const int start,const int count)
  {
   double lo=DBL_MAX;
   for(int i=0;i<count;i++)
     {
      double v=iLow(m_symbol,m_tf,start+i);
      if(v>0.0 && v<lo) lo=v;
     }
   return (lo==DBL_MAX?0.0:lo);
  }

//+------------------------------------------------------------------+
double CSignalEngine::HighestHigh(const int start,const int count)
  {
   double hi=0.0;
   for(int i=0;i<count;i++)
     {
      double v=iHigh(m_symbol,m_tf,start+i);
      if(v>hi) hi=v;
     }
   return hi;
  }

//+------------------------------------------------------------------+
double CSignalEngine::LowestRSI(const int count)
  {
   double b[];
   if(CopyBuffer(m_hRsi,0,1,count,b)!=count) return 0.0;
   double lo=DBL_MAX;
   for(int i=0;i<count;i++) if(b[i]<lo) lo=b[i];
   return (lo==DBL_MAX?0.0:lo);
  }

//+------------------------------------------------------------------+
double CSignalEngine::HighestRSI(const int count)
  {
   double b[];
   if(CopyBuffer(m_hRsi,0,1,count,b)!=count) return 0.0;
   double hi=0.0;
   for(int i=0;i<count;i++) if(b[i]>hi) hi=b[i];
   return hi;
  }

//+------------------------------------------------------------------+
double CSignalEngine::GetATR(const int shift)
  {
   double v=0.0;
   if(!CopyOne(m_hAtr,0,shift,v))
      return 0.0;
   return v;
  }

//+------------------------------------------------------------------+
//| Evaluate the most recently CLOSED bar (shift 1) for a setup.     |
//+------------------------------------------------------------------+
ENUM_SIGNAL CSignalEngine::CheckSignal(void)
  {
   double emaFast,emaSlow,emaSlowPrev,rsiNow,rsiPrev,atr;
   if(!CopyOne(m_hEmaFast,0,1,emaFast))             return SIGNAL_NONE;
   if(!CopyOne(m_hEmaSlow,0,1,emaSlow))             return SIGNAL_NONE;
   if(!CopyOne(m_hEmaSlow,0,1+m_slopeLen,emaSlowPrev)) return SIGNAL_NONE;
   if(!CopyOne(m_hRsi,0,1,rsiNow))                  return SIGNAL_NONE;
   if(!CopyOne(m_hRsi,0,2,rsiPrev))                 return SIGNAL_NONE;
   atr=GetATR(1);
   if(atr<=0.0) return SIGNAL_NONE;

   double closeNow=iClose(m_symbol,m_tf,1);
   double openNow =iOpen(m_symbol,m_tf,1);
   if(closeNow<=0.0) return SIGNAL_NONE;

   //--- ADX / DMI strength
   double adxMain=0,diPlus=0,diMinus=0;
   if(m_useAdx)
     {
      if(!CopyOne(m_hAdx,0,1,adxMain)) return SIGNAL_NONE; // ADX main
      if(!CopyOne(m_hAdx,1,1,diPlus))  return SIGNAL_NONE; // +DI
      if(!CopyOne(m_hAdx,2,1,diMinus)) return SIGNAL_NONE; // -DI
     }
   bool adxStrong = (!m_useAdx) || (adxMain>=m_adxMin);

   //--- HTF bias
   bool htfBull=true, htfBear=true;
   if(m_useHtf)
     {
      double emaHtf,closeHtf;
      if(!CopyOne(m_hEmaHtf,0,1,emaHtf)) return SIGNAL_NONE;
      closeHtf=iClose(m_symbol,m_htf,1);
      if(closeHtf<=0.0) return SIGNAL_NONE;
      htfBull=(closeHtf>emaHtf);
      htfBear=(closeHtf<emaHtf);
     }

   //--- slope
   bool emaRising  = (!m_useSlope) || (emaSlow>emaSlowPrev);
   bool emaFalling = (!m_useSlope) || (emaSlow<emaSlowPrev);

   //--- LONG ----------------------------------------------------------
   bool upTrend     = (closeNow>emaSlow) && (emaFast>emaSlow);
   bool dirOkL      = (!m_useAdx) || (diPlus>diMinus);
   bool pulledBackL = (LowestLow(1,m_pullLookback) <= emaFast + m_pullTolAtr*atr);
   bool rsiDipL     = (LowestRSI(m_pullLookback) <= m_rsiBuyZone);
   bool notExtL     = ((closeNow-emaFast) <= m_maxExtAtr*atr);
   bool confirmL    = (!m_confirmBar) || (closeNow>openNow && closeNow>emaFast);
   bool momUpL      = (rsiNow>rsiPrev);
   if(htfBull && upTrend && emaRising && adxStrong && dirOkL &&
      pulledBackL && rsiDipL && notExtL && confirmL && momUpL)
      return SIGNAL_BUY;

   //--- SHORT ---------------------------------------------------------
   bool downTrend   = (closeNow<emaSlow) && (emaFast<emaSlow);
   bool dirOkS      = (!m_useAdx) || (diMinus>diPlus);
   bool pulledBackS = (HighestHigh(1,m_pullLookback) >= emaFast - m_pullTolAtr*atr);
   bool rsiDipS     = (HighestRSI(m_pullLookback) >= m_rsiSellZone);
   bool notExtS     = ((emaFast-closeNow) <= m_maxExtAtr*atr);
   bool confirmS    = (!m_confirmBar) || (closeNow<openNow && closeNow<emaFast);
   bool momDnS      = (rsiNow<rsiPrev);
   if(htfBear && downTrend && emaFalling && adxStrong && dirOkS &&
      pulledBackS && rsiDipS && notExtS && confirmS && momDnS)
      return SIGNAL_SELL;

   return SIGNAL_NONE;
  }

//+------------------------------------------------------------------+
//| Structure-based stop price for a fresh entry.                    |
//| direction: +1 long, -1 short. entry is the intended fill price.  |
//+------------------------------------------------------------------+
double CSignalEngine::GetStopPrice(const int direction,const double entry,const double atr)
  {
   if(atr<=0.0) return 0.0;
   double minRoom,maxRoom,raw,stop;

   if(direction>0)
     {
      double swing=LowestLow(1,m_swingLook)-m_stopBufAtr*atr;
      minRoom=entry-m_atrSlMult*atr;   // at least this far below
      maxRoom=entry-m_maxStopAtr*atr;  // no further than this
      raw=m_useSwingStop ? MathMin(swing,minRoom) : minRoom;
      stop=MathMax(MathMin(raw,minRoom),maxRoom);
      return stop;
     }
   else
     {
      double swing=HighestHigh(1,m_swingLook)+m_stopBufAtr*atr;
      minRoom=entry+m_atrSlMult*atr;
      maxRoom=entry+m_maxStopAtr*atr;
      raw=m_useSwingStop ? MathMax(swing,minRoom) : minRoom;
      stop=MathMin(MathMax(raw,minRoom),maxRoom);
      return stop;
     }
  }
//+------------------------------------------------------------------+
