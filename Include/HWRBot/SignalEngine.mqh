//+------------------------------------------------------------------+
//|                                                 SignalEngine.mqh  |
//|     High Win-Rate Bot v3 - RSI Mean-Reversion signal generator   |
//+------------------------------------------------------------------+
//| Clean, high-win-rate style: buy oversold dips in an uptrend and  |
//| sell overbought rips in a downtrend.                             |
//|                                                                  |
//|  LONG  : (optional) close > trend EMA, AND a short-period RSI    |
//|          crosses DOWN through the oversold level (fresh dip).    |
//|  SHORT : (optional) close < trend EMA, AND RSI crosses UP        |
//|          through the overbought level.                          |
//|                                                                  |
//|  Optional gates (default off in the EA): higher-TF agreement,    |
//|  ADX strength, confirmation candle.                              |
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

   //--- handles
   int               m_hRsi;
   int               m_hTrendEma;
   int               m_hAtr;
   int               m_hAdx;
   int               m_hEmaHtf;

   //--- parameters
   int               m_rsiLen;
   double            m_rsiOS;
   double            m_rsiOB;
   int               m_atrPeriod;
   bool              m_useTrend;
   int               m_trendEmaLen;
   bool              m_useHtf;
   int               m_emaHtfLen;
   bool              m_useAdx;
   int               m_adxPeriod;
   double            m_adxMin;
   bool              m_useConfirm;
   //--- stop config
   bool              m_useSwingStop;
   int               m_swingLook;
   double            m_stopBufAtr;
   double            m_atrSlMult;
   double            m_maxStopAtr;

   bool              CopyOne(const int handle,const int buf,const int shift,double &value);
   double            LowestLow(const int start,const int count);
   double            HighestHigh(const int start,const int count);

public:
                     CSignalEngine(void);
                    ~CSignalEngine(void);
   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,
                          const int rsiLen,const double rsiOS,const double rsiOB,
                          const int atrPeriod,
                          const bool useTrend,const int trendEmaLen,
                          const bool useHtf,const ENUM_TIMEFRAMES htf,const int emaHtfLen,
                          const bool useAdx,const int adxPeriod,const double adxMin,
                          const bool useConfirm,
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
   m_hRsi=INVALID_HANDLE; m_hTrendEma=INVALID_HANDLE; m_hAtr=INVALID_HANDLE;
   m_hAdx=INVALID_HANDLE; m_hEmaHtf=INVALID_HANDLE;
   m_useTrend=true; m_useHtf=false; m_useAdx=false; m_useConfirm=false;
  }

CSignalEngine::~CSignalEngine(void) { Deinit(); }

//+------------------------------------------------------------------+
bool CSignalEngine::Init(const string symbol,const ENUM_TIMEFRAMES tf,
                         const int rsiLen,const double rsiOS,const double rsiOB,
                         const int atrPeriod,
                         const bool useTrend,const int trendEmaLen,
                         const bool useHtf,const ENUM_TIMEFRAMES htf,const int emaHtfLen,
                         const bool useAdx,const int adxPeriod,const double adxMin,
                         const bool useConfirm,
                         const bool useSwingStop,const int swingLook,const double stopBufAtr,
                         const double atrSlMult,const double maxStopAtr)
  {
   m_symbol=symbol; m_tf=tf; m_htf=htf;
   m_rsiLen=rsiLen; m_rsiOS=rsiOS; m_rsiOB=rsiOB; m_atrPeriod=atrPeriod;
   m_useTrend=useTrend; m_trendEmaLen=trendEmaLen;
   m_useHtf=useHtf; m_emaHtfLen=emaHtfLen;
   m_useAdx=useAdx; m_adxPeriod=adxPeriod; m_adxMin=adxMin;
   m_useConfirm=useConfirm;
   m_useSwingStop=useSwingStop; m_swingLook=swingLook; m_stopBufAtr=stopBufAtr;
   m_atrSlMult=atrSlMult; m_maxStopAtr=maxStopAtr;

   m_hRsi      = iRSI(m_symbol,m_tf,m_rsiLen,PRICE_CLOSE);
   m_hTrendEma = iMA(m_symbol,m_tf,m_trendEmaLen,0,MODE_EMA,PRICE_CLOSE);
   m_hAtr      = iATR(m_symbol,m_tf,m_atrPeriod);
   m_hAdx      = iADX(m_symbol,m_tf,m_adxPeriod);
   if(m_useHtf)
      m_hEmaHtf = iMA(m_symbol,m_htf,m_emaHtfLen,0,MODE_EMA,PRICE_CLOSE);

   if(m_hRsi==INVALID_HANDLE || m_hTrendEma==INVALID_HANDLE ||
      m_hAtr==INVALID_HANDLE || m_hAdx==INVALID_HANDLE ||
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
   if(m_hRsi!=INVALID_HANDLE){ IndicatorRelease(m_hRsi); m_hRsi=INVALID_HANDLE; }
   if(m_hTrendEma!=INVALID_HANDLE){ IndicatorRelease(m_hTrendEma); m_hTrendEma=INVALID_HANDLE; }
   if(m_hAtr!=INVALID_HANDLE){ IndicatorRelease(m_hAtr); m_hAtr=INVALID_HANDLE; }
   if(m_hAdx!=INVALID_HANDLE){ IndicatorRelease(m_hAdx); m_hAdx=INVALID_HANDLE; }
   if(m_hEmaHtf!=INVALID_HANDLE){ IndicatorRelease(m_hEmaHtf); m_hEmaHtf=INVALID_HANDLE; }
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
   double rsiNow,rsiPrev,trendEma,atr;
   if(!CopyOne(m_hRsi,0,1,rsiNow))       return SIGNAL_NONE;
   if(!CopyOne(m_hRsi,0,2,rsiPrev))      return SIGNAL_NONE;
   if(!CopyOne(m_hTrendEma,0,1,trendEma))return SIGNAL_NONE;
   atr=GetATR(1);
   if(atr<=0.0) return SIGNAL_NONE;

   double closeNow=iClose(m_symbol,m_tf,1);
   double openNow =iOpen(m_symbol,m_tf,1);
   if(closeNow<=0.0) return SIGNAL_NONE;

   //--- ADX / DMI (optional)
   double adxMain=0,diPlus=0,diMinus=0;
   if(m_useAdx)
     {
      if(!CopyOne(m_hAdx,0,1,adxMain)) return SIGNAL_NONE;
      if(!CopyOne(m_hAdx,1,1,diPlus))  return SIGNAL_NONE;
      if(!CopyOne(m_hAdx,2,1,diMinus)) return SIGNAL_NONE;
     }
   bool adxStrong=(!m_useAdx)||(adxMain>=m_adxMin);
   bool dirOkL   =(!m_useAdx)||(diPlus>diMinus);
   bool dirOkS   =(!m_useAdx)||(diMinus>diPlus);

   //--- HTF bias (optional)
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

   bool trendUp =(!m_useTrend)||(closeNow>trendEma);
   bool trendDn =(!m_useTrend)||(closeNow<trendEma);
   bool confirmL=(!m_useConfirm)||(closeNow>openNow);
   bool confirmS=(!m_useConfirm)||(closeNow<openNow);

   //--- RSI crosses (fresh dip / rip)
   bool longCross  = (rsiPrev>=m_rsiOS) && (rsiNow<m_rsiOS);
   bool shortCross = (rsiPrev<=m_rsiOB) && (rsiNow>m_rsiOB);

   if(trendUp && htfBull && adxStrong && dirOkL && longCross && confirmL)
      return SIGNAL_BUY;
   if(trendDn && htfBear && adxStrong && dirOkS && shortCross && confirmS)
      return SIGNAL_SELL;

   return SIGNAL_NONE;
  }

//+------------------------------------------------------------------+
//| Structure-based stop price for a fresh entry.                    |
//+------------------------------------------------------------------+
double CSignalEngine::GetStopPrice(const int direction,const double entry,const double atr)
  {
   if(atr<=0.0) return 0.0;
   double minRoom,maxRoom,raw,stop;

   if(direction>0)
     {
      double swing=LowestLow(1,m_swingLook)-m_stopBufAtr*atr;
      minRoom=entry-m_atrSlMult*atr;
      maxRoom=entry-m_maxStopAtr*atr;
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
