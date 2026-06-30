# Trading Toolkit

This repository contains two independent trading projects:

- **[PineScript/](PineScript/)** — *Institutional SMC Confluence Engine*, a
  non-repainting **TradingView Pine Script v6** decision-support indicator that
  only signals when a weighted confidence score reaches 80%+. See
  [`PineScript/README.md`](PineScript/README.md).
- **MQL5/** — *HighWinRateEA*, the MetaTrader 5 Expert Advisor documented below.

---

# HighWinRateEA — MT5 Trend-Pullback Expert Advisor

A complete MetaTrader 5 Expert Advisor (EA) that automates a **high win-rate
trend-pullback strategy** with full money- and trade-management. The logic and
risk controls mirror how a disciplined discretionary trader would operate:
trade only with the dominant trend, enter on pullbacks, risk a small fixed
fraction of the account per trade, and protect both individual trades and the
account on a daily basis.

> **Reality check:** No strategy turns $1,000 into $100,000 risk-free. A *high
> win rate* comes from trading with the trend on pullbacks and using a modest
> reward:risk ratio, but win rate alone is not edge — position sizing, the daily
> loss limit, and discipline are what keep the account alive. **Always backtest
> and forward-test on a demo account before risking real money.**

---

## 1. The Strategy

### Idea
Pullback-with-trend entries tend to produce a high percentage of winners because
each trade is aligned with the prevailing move, and the stop sits beyond recent
structure (measured with ATR). The EA waits for a temporary dip *against* the
trend, then enters when momentum turns back *with* the trend.

### Entry rules — LONG (short is the mirror image)
1. **Trend up:** Fast EMA (default 20) is above Slow EMA (default 50), and the
   last closed price is above the Slow EMA.
2. **Trend strong:** ADX ≥ `InpADXMin` (default 20). Filters out chop.
3. **Pullback:** within the last `InpPullbackLookback` bars price dipped to or
   below the Fast EMA.
4. **Momentum turn:** RSI crossed back **up** through `InpRSILongLevel`
   (default 45) on the last closed bar.
5. **Optional confirmation:** Stochastic %K crossed **above** %D
   (`InpUseStochConfirm`).

All conditions are evaluated on the **last closed bar** (shift 1), so signals do
not repaint.

### Exits
- **Stop loss:** `ATR × InpSLatrMult` (default 1.5).
- **Take profit:** `ATR × InpTPatrMult` (default 2.25) → ~1.5:1 reward:risk.
- **Break-even:** once price moves `ATR × InpBEtriggerATR` in profit, SL is
  moved to entry + a small offset.
- **ATR trailing stop:** after `ATR × InpTrailStartATR` of profit, the stop
  trails price by `ATR × InpTrailATRmult`.

---

## 2. Risk & Trade Management

| Control | Input | Default | Purpose |
|---|---|---|---|
| Risk per trade | `InpRiskPercent` | 1.0 % | Position size derived from stop distance so each loss costs a fixed % of equity. |
| Fixed lots override | `InpFixedLots` | 0 (off) | Use a fixed lot size instead of % risk. |
| Min stop distance | `InpMinStopPoints` | 50 pts | Floors the stop; also respects the broker's stops level. |
| Max simultaneous positions | `InpMaxPositions` | 1 | Caps exposure on this symbol/magic. |
| Max trades per day | `InpMaxTradesPerDay` | 5 | Prevents overtrading. |
| Daily loss limit | `InpMaxDailyLossPct` | 3.0 % | Stops all new trades for the day after this drawdown. |
| Daily profit target | `InpMaxDailyProfitPct` | 0 (off) | Optionally locks in a good day. |
| Spread filter | `InpMaxSpreadPoints` | 30 pts | Skips entries when spread is too wide. |
| Session filter | `InpUseSession` | off | Restrict trading hours / weekdays. |

**Position sizing formula** (in `CalcLotSize`):

```
riskMoney  = Equity × RiskPercent / 100
lossPerLot = (stopDistance / tickSize) × tickValue
lots       = riskMoney / lossPerLot   (then normalized to broker min/step/max)
```

This makes the strategy account-agnostic: the same settings scale from a $1,000
account to a $100,000 account.

---

## 3. Installation

1. Open MetaTrader 5 → **File → Open Data Folder**.
2. Copy `MQL5/Experts/HighWinRateEA.mq5` into the data folder's
   `MQL5/Experts/` directory.
3. In MetaTrader, open **MetaEditor** (F4), open `HighWinRateEA.mq5`, and press
   **Compile** (F7). You should get `0 errors, 0 warnings`.
4. Back in the terminal, refresh the **Navigator → Expert Advisors** list and
   drag `HighWinRateEA` onto a chart.
5. In the dialog enable **Allow Algo Trading** and confirm the inputs.
6. Make sure the global **Algo Trading** button in the toolbar is ON (green).

---

## 4. Backtesting (do this first)

1. **View → Strategy Tester** (Ctrl+R).
2. Select Expert `HighWinRateEA`, choose a symbol and timeframe (the strategy
   works well on **H1 / M30** for FX majors and indices).
3. Use **Every tick based on real ticks** modeling for realistic spread.
4. Set a date range of at least 1–2 years.
5. Run, then review the report: focus on **Profit Factor**, **Max Drawdown**,
   **Win %**, and **Expected Payoff**. Optimize `InpADXMin`, the EMA periods,
   and the ATR multipliers per instrument.

**Suggested starting points**
- FX majors (EURUSD, GBPUSD): H1, defaults.
- Indices (US500, NAS100): M30, `InpADXMin = 22`, `InpTPatrMult = 2.0`.
- Gold (XAUUSD): H1, `InpSLatrMult = 2.0`, `InpRiskPercent = 0.5`.

---

## 5. Parameter Reference

All inputs are grouped in the EA's properties dialog: **General, Trend Filter,
Entry, Risk Management, Trade Management, Exposure & Daily Limits, Session
Filter**. Hover any input in MetaTrader to read its inline description.

Key knobs to tune for win rate vs. profitability:
- **Higher `InpADXMin`** → fewer but cleaner trend trades (higher win rate).
- **Lower `InpTPatrMult`** → more frequent wins, smaller per-trade reward.
- **Tighter `InpSLatrMult`** → smaller losses but more stop-outs.

---

## 6. Safety Notes

- Run on a **demo account for several weeks** before going live.
- Each chart instance must use a **unique `InpMagic`** if you run multiple EAs.
- The daily loss limit and per-trade risk are your most important protections —
  do not disable them.
- Past performance (including any backtest) does not guarantee future results.

---

## File layout

```
MQL5/
  Experts/
    HighWinRateEA.mq5     # the MetaTrader 5 Expert Advisor
PineScript/
  InstitutionalSMC.pine   # the TradingView Pine v6 indicator
  README.md               # Pine indicator documentation
README.md                 # this file
```
