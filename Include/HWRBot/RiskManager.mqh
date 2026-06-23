//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh  |
//|              High Win-Rate Bot - Risk & Money Management module   |
//+------------------------------------------------------------------+
//| Responsibilities:                                                |
//|   - Position sizing from a fixed % account risk per trade        |
//|   - Daily loss / profit limits (equity guardrails)               |
//|   - Max concurrent positions & max trades per day                |
//|   - Spread filter                                                |
//|   - Trading session (time-of-day) filter                         |
//+------------------------------------------------------------------+
#property copyright "HighWinRateBot"
#property strict

//+------------------------------------------------------------------+
//| Risk manager class                                               |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   string            m_symbol;
   long              m_magic;

   //--- configuration
   double            m_riskPercent;        // % of balance risked per trade
   double            m_maxDailyLossPct;    // stop trading after this daily loss %
   double            m_dailyProfitTgtPct;  // stop trading after this daily profit %
   int               m_maxPositions;       // max concurrent positions
   int               m_maxTradesPerDay;    // cap on new trades opened per day
   int               m_maxSpreadPoints;    // reject entries above this spread
   bool              m_useSession;         // enable time-of-day filter
   int               m_startHour;          // session start (server time)
   int               m_endHour;            // session end (server time)

   //--- daily tracking
   datetime          m_dayStart;           // start of current trading day
   double            m_dayStartEquity;     // equity at day start
   int               m_tradesToday;        // trades opened today

   //--- helpers
   void              ResetDayIfNeeded();

public:
                     CRiskManager(void);
   void              Init(const string symbol,const long magic,
                          const double riskPct,const double maxDailyLossPct,
                          const double dailyProfitTgtPct,const int maxPos,
                          const int maxTradesDay,const int maxSpread,
                          const bool useSession,const int startHour,const int endHour);

   //--- gatekeeping
   bool              CanOpenNewTrade(string &reason);
   void              RegisterTradeOpened(void);

   //--- sizing
   double            CalcLotSize(const double slPriceDistance);

   //--- info / stats
   int               CountOwnPositions(void);
   double            DailyProfit(void) { ResetDayIfNeeded(); return AccountInfoDouble(ACCOUNT_EQUITY)-m_dayStartEquity; }
   double            DailyProfitPct(void);
  };

//+------------------------------------------------------------------+
CRiskManager::CRiskManager(void)
  {
   m_symbol           = _Symbol;
   m_magic            = 0;
   m_riskPercent      = 1.0;
   m_maxDailyLossPct  = 5.0;
   m_dailyProfitTgtPct= 5.0;
   m_maxPositions     = 1;
   m_maxTradesPerDay  = 5;
   m_maxSpreadPoints  = 30;
   m_useSession       = false;
   m_startHour        = 0;
   m_endHour          = 24;
   m_dayStart         = 0;
   m_dayStartEquity   = 0;
   m_tradesToday      = 0;
  }

//+------------------------------------------------------------------+
void CRiskManager::Init(const string symbol,const long magic,
                        const double riskPct,const double maxDailyLossPct,
                        const double dailyProfitTgtPct,const int maxPos,
                        const int maxTradesDay,const int maxSpread,
                        const bool useSession,const int startHour,const int endHour)
  {
   m_symbol            = symbol;
   m_magic             = magic;
   m_riskPercent       = riskPct;
   m_maxDailyLossPct   = maxDailyLossPct;
   m_dailyProfitTgtPct = dailyProfitTgtPct;
   m_maxPositions      = maxPos;
   m_maxTradesPerDay   = maxTradesDay;
   m_maxSpreadPoints   = maxSpread;
   m_useSession        = useSession;
   m_startHour         = startHour;
   m_endHour           = endHour;

   m_dayStartEquity    = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   m_dayStart          = StructToTime(dt);
   m_tradesToday       = 0;
  }

//+------------------------------------------------------------------+
//| Roll the daily counters over when a new server day begins        |
//+------------------------------------------------------------------+
void CRiskManager::ResetDayIfNeeded(void)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime today = StructToTime(dt);
   if(today!=m_dayStart)
     {
      m_dayStart       = today;
      m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      m_tradesToday    = 0;
     }
  }

//+------------------------------------------------------------------+
double CRiskManager::DailyProfitPct(void)
  {
   ResetDayIfNeeded();
   if(m_dayStartEquity<=0.0)
      return 0.0;
   return (AccountInfoDouble(ACCOUNT_EQUITY)-m_dayStartEquity)/m_dayStartEquity*100.0;
  }

//+------------------------------------------------------------------+
//| Count positions that belong to this EA on this symbol            |
//+------------------------------------------------------------------+
int CRiskManager::CountOwnPositions(void)
  {
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m_magic) continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Decide whether a new trade is allowed right now                  |
//+------------------------------------------------------------------+
bool CRiskManager::CanOpenNewTrade(string &reason)
  {
   ResetDayIfNeeded();

   //--- daily loss limit
   double dpPct=DailyProfitPct();
   if(dpPct<=-MathAbs(m_maxDailyLossPct))
     {
      reason=StringFormat("Daily loss limit hit (%.2f%%)",dpPct);
      return false;
     }

   //--- daily profit target reached -> lock in gains for the day
   if(m_dailyProfitTgtPct>0.0 && dpPct>=m_dailyProfitTgtPct)
     {
      reason=StringFormat("Daily profit target reached (%.2f%%)",dpPct);
      return false;
     }

   //--- trades-per-day cap
   if(m_maxTradesPerDay>0 && m_tradesToday>=m_maxTradesPerDay)
     {
      reason="Max trades per day reached";
      return false;
     }

   //--- concurrent positions cap
   if(CountOwnPositions()>=m_maxPositions)
     {
      reason="Max concurrent positions reached";
      return false;
     }

   //--- spread filter
   long spread=SymbolInfoInteger(m_symbol,SYMBOL_SPREAD);
   if(m_maxSpreadPoints>0 && spread>m_maxSpreadPoints)
     {
      reason=StringFormat("Spread too high (%d > %d pts)",(int)spread,m_maxSpreadPoints);
      return false;
     }

   //--- trading session filter
   if(m_useSession)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(),dt);
      bool inSession;
      if(m_startHour<=m_endHour)
         inSession=(dt.hour>=m_startHour && dt.hour<m_endHour);
      else // session wraps midnight
         inSession=(dt.hour>=m_startHour || dt.hour<m_endHour);
      if(!inSession)
        {
         reason="Outside trading session";
         return false;
        }
     }

   reason="OK";
   return true;
  }

//+------------------------------------------------------------------+
void CRiskManager::RegisterTradeOpened(void)
  {
   ResetDayIfNeeded();
   m_tradesToday++;
  }

//+------------------------------------------------------------------+
//| Position size so that hitting the SL loses ~m_riskPercent of bal |
//| slPriceDistance is the |entry - stoploss| distance in price.     |
//+------------------------------------------------------------------+
double CRiskManager::CalcLotSize(const double slPriceDistance)
  {
   if(slPriceDistance<=0.0)
      return 0.0;

   double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney    = balance*m_riskPercent/100.0;

   double tickValue    = SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize     = SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickValue<=0.0 || tickSize<=0.0)
      return 0.0;

   //--- money lost per 1.0 lot when price moves slPriceDistance against us
   double lossPerLot   = (slPriceDistance/tickSize)*tickValue;
   if(lossPerLot<=0.0)
      return 0.0;

   double lots         = riskMoney/lossPerLot;

   //--- normalize to broker volume constraints
   double minLot       = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
   double maxLot       = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MAX);
   double lotStep      = SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
   if(lotStep<=0.0) lotStep=0.01;

   lots = MathFloor(lots/lotStep)*lotStep;
   if(lots<minLot) lots=minLot;     // never below broker minimum
   if(lots>maxLot) lots=maxLot;

   //--- round to step precision to avoid float noise
   int digits=(int)MathRound(MathLog10(1.0/lotStep));
   if(digits<0) digits=0;
   lots=NormalizeDouble(lots,digits);

   return lots;
  }
//+------------------------------------------------------------------+
