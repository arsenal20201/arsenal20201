# EA RoboFibo v11.2 — MQL5 port & strategy analysis

MQ5 file: `MQL5/Experts/EA_RoboFibo_v11.2.mq5` (port of `EA_RoboFibo_source_v.11.2.mq4`).

## 1. What the EA actually does

The EA looks like a Fibonacci system, but underneath it is a **trailing-entry grid with a basket take-profit and no stop-loss**.

### Entry zone (Fibonacci)
- Takes the highest high and lowest low of the last `BarsBack` (20) bars on the **chart timeframe**.
- `LowFibo` (23.6 %) and `HighFibo` (76.4 %) mark a "low zone" and a "high zone" inside that range.

### Trailing pending order (the real entry trigger)
- An order is placed `PendingDistance` (20 points) away from price, then moved with price on every tick, **only in one direction**:
  - Buy-stop / sell-limit follow price **down**. Sell-stop / buy-limit follow price **up**.
- So the order fills only after price turns back by 20 points. That confirms a small reversal before entering.
- There is only ever **one** pending order at a time for both sides combined.

### Default mode `PendingStopReverse` (mean reversion)
| Condition | Action |
|---|---|
| No buys and Ask below the 23.6 % level | Trailing **BUY STOP**, which buys a 20-point bounce off the bottom of the range |
| No sells and Bid above the 76.4 % level | Trailing **SELL STOP**, which sells a 20-point dip from the top |
| Buys open and price has fallen `20 + Pipstep·1.5ⁿ` points below the last buy, with the current and previous bars smaller than 500 points | Another trailing buy stop (averaging down) |
| Same thing mirrored for sells | Another trailing sell stop |

The RSI, EMA and "close1 > close2" filters are **not used** in this mode. They only apply in the Limit/Follow modes. (In `PendingStopFollow` the buy side has no filter at all. That looks like a bug in the original.)

### Grid sizing (defaults, where n = number of open trades on that side)
- Next step = `20 + 50·1.5ⁿ` points: 95 → 133 → 189 → 273 → 400 → 590 → 874 …
- The total adverse move covered by about 10 orders is roughly 9,000 points (900 pips on a 5-digit pair). After that the grid effectively stops adding and just **holds**.
- Lot = `FixedLots·1.1ⁿ`. That is a mild martingale. With 0.01 lots and a 0.01 step it stays at 0.01 until the 5th order.

### Exit
- `UseTakeProfitAll = true` and `TakeProfitAll = 20`: every position on a side gets TP = volume-weighted average ± 20 **points**. That is 2 pips on a 5-digit FX pair.
- Stop-loss is off by default. Money TP/SL are 0 (off). Trailing is off.

### Filters
- Spread + commission, averaged over the last 30 ticks, must be ≤ 50 points.
- The news filter blocks new orders from 60 minutes before to 60 minutes after high-impact news. It does **not** cancel a pending order that is already trailing.
- The trading-hours filter is effectively always on (00:00–23:59).

## 2. Risk profile — why it "wins" most of the time

- The TP is tiny (about 2 pips) and averaging down pulls the break-even closer. Most baskets close green, so the **win rate is very high**, often 90 %+ in backtests.
- There is no stop-loss, so a strong one-way trend (for example a news spike, a central-bank move or a weekend gap) leaves one basket open with growing floating loss. It either:
  - comes back and closes at +2 pips, or
  - reaches a margin call, which wipes out months of small wins.
- That is the classic grid/martingale **negative-skew** profile: small frequent wins and rare very large losses. A backtest over a calm period will look excellent. Judge it by **max drawdown and worst-case floating loss**, not by win rate.
- Fixed point distances make behaviour very different per symbol and per broker. 20 points on EURUSD is 2 pips, on XAUUSD it is $0.20, and on an index it is almost nothing.

## 3. Bugs found in the MQL4 original (fixed in the MQ5)

| # | Original problem | Effect | MQ5 fix |
|---|---|---|---|
| 1 | Lots normalised to *price digits* instead of the lot step (`NormalizeDouble(lot, Digits)`) | 0.011, 0.0121 … get rejected with "invalid volume", so the grid silently fails | Rounded to `SYMBOL_VOLUME_STEP` |
| 2 | `Maxtrade` is global and not reset when the candle-size filter fails (dangling `else`) | A stale value can trigger a grid order even on large, volatile candles | Recomputed every tick |
| 3 | News: `barw1` is never assigned | The ForexFactory XML is downloaded **on every tick**, and the URL is dead anyway | MT5 built-in Economic Calendar, refreshed every `UpdateHour` hours |
| 4 | News arrays sized 150 but indexed 0..150 | Out-of-range reads | Dynamic arrays |
| 5 | `Li_180` is uninitialised | Undefined signal | Initialised to 0 |
| 6 | Close loops go forward while closing, with `Sleep(3000)` on failure | Skips orders and freezes the EA | Backward loops, no sleep |
| 7 | Virtual SL/TP only run inside `VirtualTrailing()` | `VirtualStopLoss` does nothing unless virtual trailing is also on | Checked whenever either one is on |
| 8 | Virtual SL for buys uses Ask, and the close price is wrong | Early or rejected closes | Buys use Bid, sells use Ask; CTrade picks the close price |
| 9 | Basket TP modify when price is already past the TP | Invalid-stops error spam every tick | The basket is closed at market |
| 10 | Money TP/SL checked before the targets are computed | One-tick lag | Computed first |

What stays **identical** to the original: all inputs and names, the entry and grid logic per mode, pending-order trailing, basket TP, trailing, the money targets, and the spread + commission filter.

## 4. Suggested improvements (ordered by impact)

The first four are available as inputs in the MQ5. They are OFF by default so the EA behaves like the original until you switch them on.

1. **Hard loss limit — the most important one.** Set `MaxDrawdownPercent` (for example 10–20 %). When the EA's floating loss reaches that share of the balance, it closes everything and pauses until the next day. You could also set `StoplossMoney` per basket.
2. **Cap the order size** with `MaxLotsPerOrder`. Also set `MaxOrderBuy/MaxOrderSell` to something realistic, such as 6–10 instead of 30.
3. **Cancel pending orders during news** with `DeletePendingOnNews = true`. The original still lets an armed order fill in the middle of a spike.
4. **Reduce broker load** with `MinModifyStep` (for example 5 points). The original sends a modify request on every tick, and some brokers flag that.
5. **Scale distances with ATR instead of fixed points** (not implemented yet). `PendingDistance`, `Pipstep` and `TakeProfitAll` could be set as multiples of ATR(14). That makes the EA behave the same on FX, gold and indices, and adapt to volatility.
6. **Add a regime filter** (not implemented yet). A counter-trend grid does well in ranges and fails in trends. For example, only trade when ADX(14) on H1 is below 20–25, or only buy above the D1 EMA200 and only sell below it.
7. **Make the TP cover costs** (not implemented yet). A 20-point TP with a spread limit of up to 50 points means costs can be larger than the profit. Require `TakeProfitAll ≥ 2–3 × average spread`, or use an ATR fraction.
8. **Session and weekend control** (not implemented yet). Avoid the rollover hour when spreads widen, and close or stop opening new grids on Friday evening to avoid weekend gaps.

## 5. How to test it properly

- Strategy Tester: **"Every tick based on real ticks"**, real commission, at least 3–5 years including trending periods (2020, 2022).
- The news filter is automatically inactive in the tester, because the calendar is not available there.
- Look at **equity drawdown** (not balance drawdown), the largest floating loss and the recovery factor.
- Run optimisation with walk-forward, and only on a demo account before using real money.
- The account must be **hedging**. The EA refuses to start on a netting account.
