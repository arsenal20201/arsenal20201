# PineScript — SMC / ICT Scalping Tools

Two TradingView Pine Script v5 files:

| File | What it is |
|---|---|
| `smc_ict_scalping_master_fixed.pine` | The original "SMC & ICT & Indicators + Scalping Master" indicator with 12 bugs fixed (see list below). Still an **indicator** — it draws structure, zones and signals but has no measurable win rate. |
| `smc_confluence_strategy.pine` | A new, self-contained **strategy()** that turns the SMC logic into one explicit rule set (structure flip → order-block retest → confirmed trigger → ATR stop / R-multiple target) so the TradingView Strategy Tester can produce real statistics. |

## Why two files?

The original script is a mashup of five public indicators (LuxAlgo Smart Money
Concepts, a Demand & Supply zone script, Bjorgum Key Levels + candle patterns,
a 9-indicator direction table, and a "BULB" RSI label module). An indicator
cannot have a win rate — it defines no entries, exits, stops or targets, and
several of its components repaint (signals look better on historical charts
than they behave live). Any "85% win rate" claim attached to it is
unverifiable by construction.

The strategy file exists to replace that claim with a number you can actually
measure and trust.

## Bugs fixed in `smc_ict_scalping_master_fixed.pine`

1. **Dead "ATR Length" input** — Key Levels zone width and candle filters
   silently used the SMC section's `ta.atr(200)` instead of `ta.atr(atrLen)`.
2. **Previous D/W/M high/low repainted** — `lookahead_on` leaked the current
   forming period intrabar. Now uses the last *completed* period's values.
3. **Weekly/Monthly line style inputs were ignored** (Daily style applied to
   all three timeframes).
4. **Order-block invalidation removed wrong entries** — `array.indexof` on
   arrays containing only ±1 returned the first match, not the iterated
   element, and the array was mutated during a `for…in` over it.
5. **Demand/Supply hit-check skipped zones** — elements were removed from the
   array while iterating forward over it.
6. **Supply zone boxes were gated on the Demand visibility toggle** in
   `deactivate_ds_limited()`.
7. **Demand zone tooltips said "Supply Zone"** in the all-zones loop.
8. **Inconsistent `bool choch = na` initialization** unified to `false`.
9. **Alert message copy/paste errors** — swing BOS/CHoCH alerts said
   "Internal ...", several "iternal" typos.
10. **Demand & Supply defaults (0.05% / 0.05%) produced zone spam** — raised
    to 0.5% / 0.4%, the range the script's own tooltips recommend.
11. **"Max line" input allowed 0**, conflicting with fixed-size arrays built
    from it — minimum is now 1.
12. **BULB module repaints by design** (labels are moved to new extremes after
    the fact) — now off by default, labeled as a visual aid, and its dead
    conditional label-text helpers were removed.

Known limitations that remain (inherited from the sources): heavy per-bar
loops (possible "loop takes too long" on very long 1m histories), a shared
500-object drawing budget across six subsystems (oldest drawings vanish
silently), and three overlapping zone concepts on one chart. The SMC portion
derives from LuxAlgo code published under **CC BY-NC-SA 4.0** — keep
attribution and do not sell this file. The `Bjorgum/BjCandlePatterns/2`
library import resolves on TradingView only.

## How to get a real win rate

1. Open TradingView → Pine Editor → paste `smc_confluence_strategy.pine` →
   *Add to chart*. The Strategy Tester tab fills with results.
2. Set **commission and slippage** for your broker/exchange in the strategy
   Properties (defaults: 0.05% commission, 2 ticks slippage). On 1–5m
   scalping timeframes costs decide profitability.
3. Read **Percent Profitable together with Profit Factor** — a high win rate
   with profit factor below 1.0 still loses money. Raising the
   *Take Profit (R multiple)* input lowers win rate but can raise expectancy.
4. **Walk-forward check:** tune the inputs on one date range, then verify on
   a later range you did not tune on. If performance collapses, the settings
   were curve-fit.
5. Test several symbols and timeframes before trusting a number; then
   forward-test on paper/demo before risking money.

The strategy is non-repainting: no `request.security`, no lookahead, all
signals confirmed at bar close, entries fill on the next bar's open.
