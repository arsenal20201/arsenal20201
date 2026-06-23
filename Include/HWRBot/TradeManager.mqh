//+------------------------------------------------------------------+
//|                                                 TradeManager.mqh  |
//|        High Win-Rate Bot - Order placement & open-trade care     |
//+------------------------------------------------------------------+
//| Wraps CTrade for entries and manages live positions:             |
//|   - Break-even: move SL to entry (+lock) once price runs in PnL  |
//|   - ATR / point trailing stop to ride winners                    |
//+------------------------------------------------------------------+
#property copyright "HighWinRateBot"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
class CTradeManager
  {
private:
   CTrade            m_trade;
   string            m_symbol;
   long              m_magic;
   int               m_digits;
   double            m_point;
   double            m_stopLevel;   // broker min distance (price units)

   //--- management config
   bool              m_useBreakEven;
   double            m_beTriggerR;  // move to BE after price travels this many R
   double            m_beLockPoints;// extra points locked beyond entry
   bool              m_useTrailing;
   double            m_trailAtrMult;// trailing distance as ATR multiple
   double            m_trailStartR; // start trailing after this many R

   double            NormPrice(const double price);
   bool              ModifySL(const ulong ticket,const double newSL,const double tp);

public:
                     CTradeManager(void);
   void              Init(const string symbol,const long magic,const int slippage,
                          const bool useBE,const double beTriggerR,const double beLockPts,
                          const bool useTrail,const double trailAtrMult,const double trailStartR);

   bool              OpenTrade(const int direction,const double lots,
                               const double sl,const double tp,const string comment);

   void              ManageOpenPositions(const double atr);
  };

//+------------------------------------------------------------------+
CTradeManager::CTradeManager(void)
  {
   m_symbol=_Symbol; m_magic=0; m_digits=5; m_point=_Point; m_stopLevel=0;
  }

//+------------------------------------------------------------------+
void CTradeManager::Init(const string symbol,const long magic,const int slippage,
                         const bool useBE,const double beTriggerR,const double beLockPts,
                         const bool useTrail,const double trailAtrMult,const double trailStartR)
  {
   m_symbol       = symbol;
   m_magic        = magic;
   m_digits       = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   m_point        = SymbolInfoDouble(symbol,SYMBOL_POINT);
   m_stopLevel    = SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL)*m_point;

   m_useBreakEven = useBE;
   m_beTriggerR   = beTriggerR;
   m_beLockPoints = beLockPts;
   m_useTrailing  = useTrail;
   m_trailAtrMult = trailAtrMult;
   m_trailStartR  = trailStartR;

   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetDeviationInPoints(slippage);
   m_trade.SetTypeFillingBySymbol(symbol);
   m_trade.SetAsyncMode(false);
  }

//+------------------------------------------------------------------+
double CTradeManager::NormPrice(const double price)
  {
   return NormalizeDouble(price,m_digits);
  }

//+------------------------------------------------------------------+
//| Open a market order. direction: +1 buy, -1 sell                  |
//+------------------------------------------------------------------+
bool CTradeManager::OpenTrade(const int direction,const double lots,
                              const double sl,const double tp,const string comment)
  {
   if(lots<=0.0)
     {
      Print("TradeManager: invalid lot size, trade skipped");
      return false;
     }

   double price,slN,tpN;
   bool ok=false;

   if(direction>0)
     {
      price=SymbolInfoDouble(m_symbol,SYMBOL_ASK);
      slN=NormPrice(sl);
      tpN=NormPrice(tp);
      //--- respect broker minimum stop distance
      if(price-slN < m_stopLevel) slN=NormPrice(price-m_stopLevel);
      if(tpN-price < m_stopLevel) tpN=NormPrice(price+m_stopLevel);
      ok=m_trade.Buy(lots,m_symbol,price,slN,tpN,comment);
     }
   else if(direction<0)
     {
      price=SymbolInfoDouble(m_symbol,SYMBOL_BID);
      slN=NormPrice(sl);
      tpN=NormPrice(tp);
      if(slN-price < m_stopLevel) slN=NormPrice(price+m_stopLevel);
      if(price-tpN < m_stopLevel) tpN=NormPrice(price-m_stopLevel);
      ok=m_trade.Sell(lots,m_symbol,price,slN,tpN,comment);
     }

   if(!ok)
      PrintFormat("TradeManager: order failed retcode=%d (%s)",
                  m_trade.ResultRetcode(),m_trade.ResultRetcodeDescription());
   return ok;
  }

//+------------------------------------------------------------------+
bool CTradeManager::ModifySL(const ulong ticket,const double newSL,const double tp)
  {
   if(!m_trade.PositionModify(ticket,NormPrice(newSL),NormPrice(tp)))
     {
      PrintFormat("TradeManager: modify SL failed ticket=%I64u retcode=%d",
                  ticket,m_trade.ResultRetcode());
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Walk our open positions: apply break-even then trailing stop.    |
//+------------------------------------------------------------------+
void CTradeManager::ManageOpenPositions(const double atr)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m_magic) continue;

      long   type   = PositionGetInteger(POSITION_TYPE);
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);

      //--- risk per unit (R) from the original stop distance
      double rDist  = MathAbs(entry-sl);
      if(rDist<=0.0) continue;

      double bid    = SymbolInfoDouble(m_symbol,SYMBOL_BID);
      double ask    = SymbolInfoDouble(m_symbol,SYMBOL_ASK);

      if(type==POSITION_TYPE_BUY)
        {
         double profitDist = bid-entry;

         //--- break-even
         if(m_useBreakEven && profitDist >= m_beTriggerR*rDist)
           {
            double beSL = entry + m_beLockPoints*m_point;
            if(beSL>sl + m_point) { ModifySL(ticket,beSL,tp); sl=beSL; }
           }

         //--- trailing stop
         if(m_useTrailing && atr>0.0 && profitDist >= m_trailStartR*rDist)
           {
            double trailSL = bid - m_trailAtrMult*atr;
            if(trailSL>sl + m_point && trailSL<bid)
               ModifySL(ticket,trailSL,tp);
           }
        }
      else if(type==POSITION_TYPE_SELL)
        {
         double profitDist = entry-ask;

         if(m_useBreakEven && profitDist >= m_beTriggerR*rDist)
           {
            double beSL = entry - m_beLockPoints*m_point;
            if(sl<=0.0 || beSL<sl - m_point) { ModifySL(ticket,beSL,tp); sl=beSL; }
           }

         if(m_useTrailing && atr>0.0 && profitDist >= m_trailStartR*rDist)
           {
            double trailSL = ask + m_trailAtrMult*atr;
            if((sl<=0.0 || trailSL<sl - m_point) && trailSL>ask)
               ModifySL(ticket,trailSL,tp);
           }
        }
     }
  }
//+------------------------------------------------------------------+
