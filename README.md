# High Win-Rate Bot — MetaTrader 5 Expert Advisor

A complete, production-structured MT5 Expert Advisor (EA) that automates a
**trend-pullback** strategy with strict, layered **risk management**. It is built
the way a disciplined trader actually operates: trade *with* the higher trend,
buy pullbacks into value (not extended moves), confirm momentum, and protect
capital with hard daily limits and dynamic trade management.

> ⚠️ **Disclaimer:** This is an educational/automation tool, not financial advice.
> No strategy has a guaranteed win rate. **Always forward-test on a DEMO account
> for weeks before risking real money.** Past performance does not guarantee
> future results. Trade only money you can afford to lose.

---

## The strategy (why it aims for a high win rate)

High win-rate systems share three traits: they only trade in the direction of
the dominant trend, they enter on pullbacks instead of chasing, and they cut
risk aggressively. This EA encodes exactly that, top-down.

0. **Higher-timeframe bias** (optional, on by default) — A higher-TF EMA
   (default **H1 EMA 200**) must agree with the trade direction before anything
   else is considered. This is the top-down filter desks use to avoid
   counter-trend traps.
1. **Trend filter** — A slow EMA (default **EMA 200**) defines the only side we
   may trade. Price above it → longs only. Price below it → shorts only. We never
   fight the trend.
2. **Pullback into value** — A faster EMA (default **EMA 50**) keeps us aligned
   with the active swing, and **RSI** must dip into a value zone on the pullback
   (≤ 40 in an uptrend, ≥ 60 in a downtrend). This avoids buying tops / selling
   bottoms.
3. **Momentum confirmation** — RSI must turn back in the trend direction on the
   most recent *closed* bar. That turn is the entry trigger, so we enter as the
   pullback resumes into the trend.
4. **Volatility floor** (optional) — An ATR minimum skips dead, low-range
   markets where the edge breaks down.

Stops and targets are **ATR-based**, so they adapt to each instrument's
volatility and keep the risk:reward ratio consistent.

```
Entry (LONG):  H1 close > H1 EMA200            (higher-TF bias)
               AND close > EMA200 AND EMA50 > EMA200
               AND RSI dipped <= 40 on the prior bar
               AND RSI is now turning back up
SL  = entry - ATR * 1.5
TP  = entry + (SL distance * RewardRiskRatio)

Lifecycle:     +1R -> close 50%, move stop to break-even
               then trail the runner by ATR * 2.0
```

Shorts are the mirror image.

---

## Risk management (the part that actually grows the account)

Every layer below is configurable from the EA inputs:

| Control | Default | What it does |
|---|---|---|
| **Risk % per trade** | 1.0% | Lot size is computed so a stop-out loses exactly this % of balance — regardless of symbol or stop distance. |
| **Daily loss limit** | 4% | Stops opening new trades once the day is down this much. Protects against tilt / bad days. |
| **Daily profit lock** | 6% | Stops trading once the day's target is hit, locking in green days. (Set 0 to disable.) |
| **Max concurrent positions** | 1 | Caps simultaneous exposure. |
| **Max trades per day** | 5 | Prevents over-trading. |
| **Spread filter** | 30 pts | Rejects entries when spread is abnormally wide. |
| **Session filter** | off | Optionally trade only within chosen server hours. |
| **Partial take-profit** | on | Closes 50% at 1R and moves the rest to break-even — banks profit early and lifts the win rate. |
| **Break-even** | on | Moves SL to entry (+lock) after price runs 1R in profit — turns a winner into a risk-free trade. |
| **ATR trailing stop** | on | Trails the stop by an ATR multiple after 1.5R to ride the runner. |

Position size is derived from real broker tick value/size, so it is correct on
forex, indices, metals, and crypto CFDs alike.

---

## Files

```
Experts/
  HighWinRateBot.mq5      # main Expert Advisor (compile this)
Include/HWRBot/
  SignalEngine.mqh        # trend-pullback signal logic + ATR
  RiskManager.mqh         # position sizing, daily limits, filters
  TradeManager.mqh        # order placement, break-even, trailing
docs/
  STRATEGY.md             # deeper notes, tuning & backtesting guide
```

---

## Installation

1. Open MetaTrader 5 → **File → Open Data Folder**.
2. Copy `Experts/HighWinRateBot.mq5` into `MQL5/Experts/`.
3. Copy the `Include/HWRBot/` folder into `MQL5/Include/` (so you have
   `MQL5/Include/HWRBot/SignalEngine.mqh`, etc.).
4. In MetaTrader, open **MetaEditor** (F4), open `HighWinRateBot.mq5`, and press
   **Compile** (F7). It should compile with 0 errors.
5. Restart MT5 or refresh the Navigator. Drag **HighWinRateBot** onto a chart.
6. In the dialog, enable **Algo Trading** and allow it to trade.

---

## Recommended workflow

1. **Backtest** in the Strategy Tester (Ctrl+R) on several months of *"Every tick
   based on real ticks"* data for your symbol/timeframe.
2. Tune inputs (see `docs/STRATEGY.md`) — favor robustness over a perfect curve.
3. **Forward-test on DEMO** for several weeks with your real intended settings.
4. Go live small. Start at **0.5% risk** and only scale once the live results
   match the demo.

### Sensible starting presets

- **Symbol/TF:** EURUSD or XAUUSD on **M15**.
- **Risk:** 1% per trade, 4% daily loss limit, 6% daily profit lock.
- **R:R:** 1.5, ATR SL multiple 1.5.

---

## Compiling / contributing

The code targets the MQL5 standard library (`<Trade/Trade.mqh>`) and compiles in
MetaEditor (build 3000+). It is split into focused, documented modules so the
signal logic, risk rules, and execution can each be changed independently.

---

*Built for disciplined, rules-based trading. Manage your risk first; the profits
follow.*
