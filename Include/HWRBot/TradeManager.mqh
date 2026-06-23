//+------------------------------------------------------------------+
//|                                                 TradeManager.mqh  |
//|        High Win-Rate Bot - Order placement & open-trade care     |
//+------------------------------------------------------------------+
//| Wraps CTrade for entries and actively manages live positions     |
//| with a per-position state machine so each action fires once:     |
//|   1. Partial take-profit  : close a slice at the first target,   |
//|                             then lock the rest at break-even      |
//|   2. Break-even           : move SL to entry (+lock) after N R    |
//|   3. ATR trailing stop    : ride the runner after the move ext.  |
//|                                                                  |
//| State is keyed by position ticket and re-derived from live       |
//| positions, so it self-heals across restarts.                     |
//+------------------------------------------------------------------+
#property copyright "HighWinRateBot"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Per-position management state                                    |
//+------------------------------------------------------------------+
struct SPositionState
  {
   ulong             ticket;
   double            initVolume;   // volume first time we saw the position
   double            entry;        // open price
   double            rDist;        // 1R = |entry - initial SL| in price
   bool              partialDone;
   bool              beDone;
  };

//+------------------------------------------------------------------+
class CTradeManager
  {
private:
   CTrade            m_trade;
   string            m_symbol;
   long              m_magic;
   int               m_digits;
   double            m_point;
   double            m_stopLevel;     // broker min stop distance (price)
   double            m_minLot;
   double            m_lotStep;
   int               m_volDigits;

   //--- management config
   bool              m_usePartial;
   double            m_partialTriggerR;
   double            m_partialPct;     // % of initial volume to close
   bool              m_useBreakEven;
   double            m_beTriggerR;
   double            m_beLockPoints;
   bool              m_useTrailing;
   double            m_trailAtrMult;
   double            m_trailStartR;

   //--- live position state table
   SPositionState    m_states[];

   //--- helpers
   double            NormPrice(const double price)   { return NormalizeDouble(price,m_digits); }
   double            NormVolume(const double volume);
   bool              ModifyStops(const ulong ticket,const double newSL,const double tp);
   int               FindState(const ulong ticket);
   int               AddState(const ulong ticket);
   void              PruneClosedStates(void);
   bool              IsOwn(const ulong ticket);

public:
                     CTradeManager(void);
   void              Init(const string symbol,const long magic,const int slippage,
                          const bool usePartial,const double partialTriggerR,const double partialPct,
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
   m_minLot=0.01; m_lotStep=0.01; m_volDigits=2;
  }

//+------------------------------------------------------------------+
void CTradeManager::Init(const string symbol,const long magic,const int slippage,
                         const bool usePartial,const double partialTriggerR,const double partialPct,
                         const bool useBE,const double beTriggerR,const double beLockPts,
                         const bool useTrail,const double trailAtrMult,const double trailStartR)
  {
   m_symbol          = symbol;
   m_magic           = magic;
   m_digits          = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   m_point           = SymbolInfoDouble(symbol,SYMBOL_POINT);
   m_stopLevel       = SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL)*m_point;
   m_minLot          = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   m_lotStep         = SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(m_lotStep<=0.0) m_lotStep=0.01;
   m_volDigits       = (int)MathMax(0,MathRound(MathLog10(1.0/m_lotStep)));

   m_usePartial      = usePartial;
   m_partialTriggerR = partialTriggerR;
   m_partialPct      = partialPct;
   m_useBreakEven    = useBE;
   m_beTriggerR      = beTriggerR;
   m_beLockPoints    = beLockPts;
   m_useTrailing     = useTrail;
   m_trailAtrMult    = trailAtrMult;
   m_trailStartR     = trailStartR;

   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetDeviationInPoints(slippage);
   m_trade.SetTypeFillingBySymbol(symbol);
   m_trade.SetAsyncMode(false);

   ArrayResize(m_states,0);
  }

//+------------------------------------------------------------------+
double CTradeManager::NormVolume(const double volume)
  {
   double v=MathFloor(volume/m_lotStep)*m_lotStep;
   return NormalizeDouble(v,m_volDigits);
  }

//+------------------------------------------------------------------+
bool CTradeManager::IsOwn(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL)!=m_symbol) return false;
   if(PositionGetInteger(POSITION_MAGIC)!=m_magic)  return false;
   return true;
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
      slN=NormPrice(sl); tpN=NormPrice(tp);
      if(price-slN < m_stopLevel) slN=NormPrice(price-m_stopLevel);
      if(tpN-price < m_stopLevel) tpN=NormPrice(price+m_stopLevel);
      ok=m_trade.Buy(lots,m_symbol,price,slN,tpN,comment);
     }
   else if(direction<0)
     {
      price=SymbolInfoDouble(m_symbol,SYMBOL_BID);
      slN=NormPrice(sl); tpN=NormPrice(tp);
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
bool CTradeManager::ModifyStops(const ulong ticket,const double newSL,const double tp)
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
int CTradeManager::FindState(const ulong ticket)
  {
   for(int i=0;i<ArraySize(m_states);i++)
      if(m_states[i].ticket==ticket)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| Record a freshly seen position (selected by caller).             |
//+------------------------------------------------------------------+
int CTradeManager::AddState(const ulong ticket)
  {
   SPositionState st;
   st.ticket      = ticket;
   st.initVolume  = PositionGetDouble(POSITION_VOLUME);
   st.entry       = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl      = PositionGetDouble(POSITION_SL);
   st.rDist       = (sl>0.0 ? MathAbs(st.entry-sl) : 0.0);
   st.partialDone = false;
   st.beDone      = false;

   int n=ArraySize(m_states);
   ArrayResize(m_states,n+1);
   m_states[n]=st;
   return n;
  }

//+------------------------------------------------------------------+
//| Drop state rows whose positions are no longer open / not ours.   |
//+------------------------------------------------------------------+
void CTradeManager::PruneClosedStates(void)
  {
   for(int i=ArraySize(m_states)-1;i>=0;i--)
     {
      if(!IsOwn(m_states[i].ticket))
        {
         int last=ArraySize(m_states)-1;
         if(i!=last) m_states[i]=m_states[last];
         ArrayResize(m_states,last);
        }
     }
  }

//+------------------------------------------------------------------+
//| Walk our open positions: partial-TP, then break-even, then trail |
//+------------------------------------------------------------------+
void CTradeManager::ManageOpenPositions(const double atr)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m_magic)  continue;

      int idx=FindState(ticket);
      if(idx<0) idx=AddState(ticket);

      long   type   = PositionGetInteger(POSITION_TYPE);
      double entry  = m_states[idx].entry;
      double rDist  = m_states[idx].rDist;
      double tp     = PositionGetDouble(POSITION_TP);
      double sl     = PositionGetDouble(POSITION_SL);
      double vol    = PositionGetDouble(POSITION_VOLUME);
      if(rDist<=0.0) continue;   // no stop recorded -> nothing to scale against

      double bid    = SymbolInfoDouble(m_symbol,SYMBOL_BID);
      double ask    = SymbolInfoDouble(m_symbol,SYMBOL_ASK);
      bool   isBuy  = (type==POSITION_TYPE_BUY);
      double profitDist = isBuy ? (bid-entry) : (entry-ask);

      //--- 1) PARTIAL TAKE-PROFIT (also flips the trade to break-even) ----
      if(m_usePartial && !m_states[idx].partialDone &&
         profitDist >= m_partialTriggerR*rDist)
        {
         double closeVol = NormVolume(m_states[idx].initVolume*m_partialPct/100.0);
         double remain   = NormVolume(vol-closeVol);
         if(closeVol>=m_minLot && remain>=m_minLot)
           {
            if(m_trade.PositionClosePartial(ticket,closeVol))
              {
               m_states[idx].partialDone=true;
               double beSL = isBuy ? entry+m_beLockPoints*m_point
                                   : entry-m_beLockPoints*m_point;
               if(ModifyStops(ticket,beSL,tp))
                 { sl=beSL; m_states[idx].beDone=true; }
               PrintFormat("Partial TP: closed %.2f of %I64u, runner to break-even",closeVol,ticket);
              }
           }
         else
            m_states[idx].partialDone=true; // volume too small to split; don't retry
        }

      //--- 2) BREAK-EVEN ------------------------------------------------
      if(m_useBreakEven && !m_states[idx].beDone &&
         profitDist >= m_beTriggerR*rDist)
        {
         double beSL = isBuy ? entry+m_beLockPoints*m_point
                             : entry-m_beLockPoints*m_point;
         bool better = isBuy ? (beSL>sl+m_point) : (sl<=0.0 || beSL<sl-m_point);
         if(better && ModifyStops(ticket,beSL,tp))
           { sl=beSL; m_states[idx].beDone=true; }
        }

      //--- 3) ATR TRAILING STOP ----------------------------------------
      if(m_useTrailing && atr>0.0 && profitDist >= m_trailStartR*rDist)
        {
         if(isBuy)
           {
            double trailSL=bid-m_trailAtrMult*atr;
            if(trailSL>sl+m_point && trailSL<bid)
               ModifyStops(ticket,trailSL,tp);
           }
         else
           {
            double trailSL=ask+m_trailAtrMult*atr;
            if((sl<=0.0 || trailSL<sl-m_point) && trailSL>ask)
               ModifyStops(ticket,trailSL,tp);
           }
        }
     }

   PruneClosedStates();
  }
//+------------------------------------------------------------------+
