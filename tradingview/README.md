# TradingView version (Pine Script v5)

`HighWinRateStrategy.pine` is a TradingView **strategy** port of the MT5 EA. It
runs in TradingView's built-in **Strategy Tester** so you can backtest the same
trend-pullback logic on any symbol/timeframe.

## How to load & backtest

1. Open a chart on TradingView (pick your symbol, e.g. `OANDA:EURUSD`, and the
   timeframe you want to trade, e.g. **15m**).
2. Open the **Pine Editor** (bottom panel).
3. Paste the full contents of `HighWinRateStrategy.pine`.
4. Click **Save**, then **Add to chart**.
5. Open the **Strategy Tester** tab to see the equity curve, win rate, profit
   factor, max drawdown and the trade list.
6. Click the strategy's **settings (gear) icon** to tune inputs (risk %, R:R,
   HTF filter, partial TP, etc.) — they mirror the MT5 EA's inputs.

## What carries over from the MT5 EA

- Higher-timeframe trend filter, EMA200/EMA50 trend, RSI pullback + momentum turn
- ATR stop-loss, R:R take-profit, ATR volatility floor
- Scale-out partial take-profit, break-even, ATR trailing stop
- %-equity risk position sizing, daily loss limit, daily profit lock,
  max trades/day, session filter

## Differences vs MT5 (platform limitations)

- **No broker spread / fill modes** — TradingView has no real spread, so the
  spread filter and MT5 fill settings don't exist here. Add **commission** and
  **slippage** in the `strategy(...)` header (or the tester's Properties tab) to
  make results realistic.
- **One position at a time** (`pyramiding = 0`) — matches the EA's default
  `MaxPositions = 1`.
- **Position sizing** uses `equity * risk% / (stopDistance * pointvalue)`. Verify
  the sizing looks sane for your instrument in the trade list; TradingView's
  contract specs differ from your MT5 broker, so the two backtests won't be
  identical — use each on its own platform.

## Important

Backtest results are **not** a promise of live performance. Use realistic
commission/slippage, test across different market regimes, then forward-test on
paper before risking real money.
