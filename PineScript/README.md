# Institutional SMC Confluence Engine — TradingView Pine Script v6

A professional, non-repainting **decision-support indicator** that automates a
discretionary Smart-Money / price-action workflow. It only prints a **BUY** or
**SELL** signal when a weighted **confidence score reaches the threshold
(default 80%)** *and* every required confirmation agrees. When conditions are
unclear it shows nothing.

> **Not financial advice.** This is an analysis tool. Always backtest and
> forward-test before risking capital. No indicator guarantees profit.

---

## 1. What it does

The engine fuses many independent factors into one score and one clean signal:

| Module | Purpose |
|---|---|
| **Multi-timeframe trend** | EMA50 vs EMA200 on 3 higher timeframes must all agree (15m / 1H / 4H by default). |
| **Heikin Ashi engine** | Internally computed HA candles (chart-type independent): colour, body size, wicks, consecutive run, strong-candle detection. |
| **Market structure** | Confirmed swing pivots → HH / HL / LH / LL, **BOS** and **CHoCH**. |
| **Liquidity sweeps** | Equal highs/lows, stop hunts, false breakouts with reclaim confirmation. |
| **Supply & demand zones** | Drawn from confirmed swings; fresh vs mitigated; bounded count. |
| **Fair value gaps** | 3-candle imbalance; entries only when price returns into a still-valid gap. |
| **Order blocks** | Last opposite candle before an impulsive BOS/CHoCH move; unmitigated only. |
| **Volume** | Current > 20-period average × multiplier; flags institutional volume. |
| **ATR filter** | Skips low-volatility conditions (ATR must be above its average). |
| **ADX filter** | Trades only when ADX > 25 (ignores ranging markets). |
| **RSI** | BUY 55–70, SELL 30–45 (avoids overextension). |
| **VWAP** | Longs only above VWAP, shorts only below. |
| **EMA pullback** | Requires a recent tag of EMA20/50 before continuation entries. |
| **Sessions** | London / New York / overlap, toggleable. |
| **Dynamic S/R** | Auto support/resistance; blocks buying into resistance / selling into support. |

---

## 2. Confidence scoring (total = 100)

| Factor | Weight |
|---|---|
| Higher-timeframe trend | 20 |
| Heikin Ashi confirmation | 20 |
| Market structure | 15 |
| Liquidity sweep | 10 |
| Order block | 10 |
| Fair value gap | 10 |
| Volume | 5 |
| ADX | 5 |
| ATR | 5 |
| Risk:Reward | 5 |

A signal also passes **hard gates** (MTF trend, HA, structure, RSI, VWAP,
session, pullback, ADX, ATR, S/R guard, RR ≥ 1:2) on top of the score, so a high
score alone is never enough.

---

## 3. Risk management

For every signal the engine computes and draws:

- **Stop loss** = entry ∓ `ATR × slAtrMult`
- **Take profit** = entry ± `risk × minRR`
- **Risk:Reward** — trades below **1:2** are rejected
- **SL line, TP line, risk box, target box**
- **ATR trailing stop** that follows the trade

**Exit** fires on any of: Heikin Ashi trend flip, market-structure break, ATR
trailing-stop hit, take-profit reached, or stop-loss hit.

---

## 4. Non-repainting design

- Swing structure uses **confirmed pivots** (`pivotLen` bars each side).
- Higher-timeframe values use the **PineCoders non-repaint idiom**:
  `request.security(... expr[1], lookahead = barmerge.lookahead_on)` — the last
  *closed* HTF value, no future leak.
- Heikin Ashi is computed from the chart's real OHLC, so it behaves identically
  no matter which chart type is selected.
- `alert()` messages fire `once_per_bar_close`.
- No future-referencing series, no lookahead bias.

---

## 5. Dashboard

A live table shows: Trend (MTF), Structure, Confidence %, Volume, ATR, ADX, RSI,
VWAP status, Session, Risk:Reward, Signal strength, and current state
(Flat / Long open / Short open / BUY / SELL). Position is configurable.

---

## 6. Alerts

Selectable `alertcondition` options plus rich dynamic `alert()` messages:
BUY, SELL, Strong BUY, Strong SELL, Trend change (BOS / CHoCH), Liquidity Sweep,
Order Block Touch, FVG Entry, Take Profit, Stop Loss, Exit.

---

## 7. Installation

1. Open TradingView → **Pine Editor**.
2. Paste the contents of [`InstitutionalSMC.pine`](./InstitutionalSMC.pine).
3. **Add to chart**. Open the gear ⚙️ to configure inputs.
4. Create alerts from **Add alert → Condition → SMC-Engine**.

### Recommended starting point
- Use a **normal candlestick** chart (HA is computed internally — do not stack
  it on an HA chart or the conversion is applied twice).
- Lower timeframe **5m / 15m**, with the three HTFs left at 15m / 1H / 4H.
- Keep the threshold at **80**; raise to **90** for only the strongest setups.

---

## 6b. Tuning — clutter vs. missed signals

The engine deliberately favours quality over quantity, but two settings control
the trade-off most people need to adjust:

**If structure looks noisy (too many BOS / CHoCH):** each swing level now fires
**at most one** break event (internal *broken* flags), so the main lever is
**`Swing pivot length`** (default **8**). Raise it (12–20) for fewer, cleaner,
higher-timeframe swings; lower it for more reactive structure. You can also hide
labels with **`Show BOS / CHoCH labels`** and **`Show liquidity-sweep labels`**.

**If it misses obvious moves / gives no signals — check the dashboard first.**
Every greyed-out row is a filter that is currently blocking a signal. The usual
culprits:

| Symptom on dashboard | Cause | Fix |
|---|---|---|
| Trend (MTF) = BEARISH during an up-move | All 3 higher TFs (EMA50/200) must align; a reversal off the lows fights a still-bearish 4H EMA200 | Lower **`Min higher TFs that must agree`** to **2** (default) or **1** for reversals |
| Session = Off-session | Session filter blocked the move | Session filter is **off by default** now; only enable it (and set the timezone) for FX/index session trading |
| ATR vs avg = Low | Volatility filter | ATR is **score-only by default**; enable *ATR is a hard filter* only if you want it to block |
| Near a swing high/low | S/R guard | It now ignores **already-broken** levels, so breakouts pass; toggle off via *S/R Guard* |

> The original "all 3 HTFs must agree on EMA50/200" rule is pure trend-following
> and structurally **cannot** signal a reversal until the higher-timeframe
> EMA200 flips (hours later). Min-agree = 2 keeps a strong bias while letting
> early continuation/reversal setups through.

---

## 8. Inputs (all configurable)

Grouped in the settings panel: General, Multi-Timeframe Trend, Heikin Ashi,
Market Structure, Liquidity, Volume, ATR, ADX, RSI, EMA Pullback, VWAP,
S/R Guard, Sessions, Dashboard & Colors, Alerts — covering EMA lengths, RSI
bounds, ADX threshold, ATR/volume multipliers, session windows, RR, score
threshold, timeframes, colours, dashboard position and alert toggles.

Key tuning inputs added for signal/clutter control:
- **Min higher TFs that must agree** (1–3, default 2) — relaxes the strict
  trend gate so reversals can signal.
- **Swing pivot length** (default 8) — primary clutter control for structure.
- **Show BOS / CHoCH labels**, **Show liquidity-sweep labels** — declutter.
- **ATR is a hard filter** (default off) — keep ATR as score-only.
- **S/R Guard** (default on, ignores broken levels).
- **Trade only inside sessions** (default off).

---

## File layout

```
PineScript/
  InstitutionalSMC.pine   # the indicator
  README.md               # this file
```
