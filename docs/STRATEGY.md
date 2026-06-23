# Strategy notes, tuning & backtesting

This document goes deeper than the README on *how* the strategy works, *why* each
rule exists, and *how* to tune and validate it responsibly.

## 1. The edge in plain language

Markets spend a large share of time trending, and within trends they pull back
before continuing. The highest-probability, lowest-risk place to enter a trend is
**at the end of a pullback**, not at a breakout extreme. This EA waits for:

- The market to prove it is trending (price vs. EMA200, EMA50 vs. EMA200), then
- A pullback to dump short-term momentum (RSI into a value zone), then
- Momentum to flip back in the trend direction (RSI turning up/down).

By entering as the pullback resumes, the stop can sit just beyond the recent
swing (here approximated with an ATR buffer), giving a tight risk and a high
proportion of trades that work — the profile of a high win-rate system.

> A high win rate is **not** the same as high profitability. A system that wins
> 70% but loses 3x what it wins is a losing system. That is why this EA pairs the
> entry edge with strict R:R, break-even, and trailing logic.

## 2. Parameter reference & tuning

### Trend / signal
- `InpEmaSlow` (200): the trend gate. Larger = stronger trends, fewer trades.
- `InpEmaFast` (50): swing alignment. Must be `< InpEmaSlow`.
- `InpRsiBuyZone` / `InpRsiSellZone` (40 / 60): how deep a pullback must be.
  Tighter to 30/70 = fewer but deeper, higher-quality pullbacks.
- `InpRsiPeriod` (14): standard; 7–9 reacts faster, 21 is smoother.

### Stops & targets
- `InpAtrSlMult` (1.5): stop distance in ATR. Too tight = stopped by noise; too
  wide = small position sizes. 1.2–2.0 is a sane range.
- `InpRewardRiskRatio` (1.5): target as a multiple of risk. With a high win rate,
  1.2–1.5 keeps expectancy positive; higher R:R lowers win rate.

### Risk
- `InpRiskPercent` (1.0): the single most important number. Lot size is solved
  from this and the stop distance. **Keep ≤ 2%.**
- `InpMaxDailyLossPct` (4.0): daily circuit breaker on equity.
- `InpDailyProfitTargetPct` (6.0): stop after a good day (0 disables).
- `InpMaxPositions` / `InpMaxTradesPerDay`: exposure and over-trading caps.

### Trade management
- Break-even (`InpBreakEvenTriggerR` = 1.0): once price moves 1R in favor, SL
  jumps to entry + a small lock. Many trades then close at worst break-even.
- Trailing (`InpTrailAtrMult` = 2.0, `InpTrailStartR` = 1.5): rides the runners.

## 3. Position sizing math

```
riskMoney   = balance * RiskPercent / 100
lossPerLot  = (stopDistance / tickSize) * tickValue
lots        = riskMoney / lossPerLot      (then clamped to broker min/max/step)
```

Because it uses the broker's `SYMBOL_TRADE_TICK_VALUE` and `..._TICK_SIZE`, the
same risk % produces correct sizing on FX, metals, indices and crypto CFDs.

## 4. Backtesting checklist

1. Strategy Tester → model **"Every tick based on real ticks"**.
2. Use a broker-realistic spread and at least 6–12 months of data.
3. Look at: profit factor (> 1.3), max drawdown (< your tolerance), win rate,
   average R, and the **equity curve smoothness** — not just net profit.
4. Run a quick **optimization** on `InpAtrSlMult` and `InpRewardRiskRatio`, but
   prefer a broad plateau of good results over a single sharp peak (which is
   usually curve-fitting).

## 5. Going live safely

- Forward-test on **demo** with final settings for several weeks.
- Start live at **half** your intended risk.
- Keep the daily loss limit on at all times.
- Review weekly; a strategy that decays should be paused, not "averaged into".

## 6. Ideas for extension

- Replace the ATR stop with a true swing-low/high stop for tighter risk.
- Add a higher-timeframe trend filter (e.g. confirm M15 entries with H1 EMA200).
- Add a news/economic-calendar blackout window.
- Partial take-profit: close half at 1R, trail the rest.
