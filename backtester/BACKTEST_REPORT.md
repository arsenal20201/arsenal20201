# XAUUSD SMC Confluence Scalper — Backtest Report

**Data:** 379,893 real XAUUSD 1-minute candles, 2025-06-01 → 2026-06-26
(HistData.com feed, fetched by `.github/workflows/fetch-data.yml`; Dukascopy
currently blocks GitHub runner IPs). Resampled to 3m / 5m / 15m.

**Method:** every parameter set was simulated bar-by-bar with conservative
execution — signals on closed bars only, fills at next bar open, $0.30
bid/ask spread + $0.05 slippage per side, stop assumed to fill before target
when a bar touches both, positions force-flat before the weekend.
216-combination grid search **trained on Jul 2025 – Mar 2026** and the top
candidates **validated out-of-sample on Apr – Jun 2026**. R = initial risk
per trade (entry to stop distance).

## Verdict per timeframe

| TF | Verdict |
|----|---------|
| **15m** | **Real edge, survives validation. Trade this one.** |
| 3m | Modest edge (CHoCH-only), thinner sample. Secondary. |
| **5m** | **Every finalist collapsed out-of-sample (PF 0.28–0.88). Do NOT trade this strategy on 5m.** |

## Primary: 15m settings (validated)

`swing_len=4, rr_mult=1.0, stop_atr_mult=0.5, ema_len=200, session=12–17 UTC,
break_mode=all, min_risk_spread_mult=3`

| Window | Trades | Win rate | Profit factor | Avg R | Total R | Max DD (R) |
|---|---|---|---|---|---|---|
| Train (Jul 25–Mar 26) | 96 | 69.8% | 2.18 | +0.37 | +35.2 | 3.0 |
| **Validation (Apr–Jun 26)** | 31 | **74.2%** | **2.76** | +0.45 | +14.1 | 2.0 |
| Full 13 months | 130 | 69.2% | 2.13 | +0.36 | +46.3 | 4.0 |

- 11 of 13 months positive; worst month −0.01R; max 4 consecutive losses.
- Parameter plateau (robust, not a lucky spike): swing_len 3/4/5, session
  11–17/12–17/12–18, rr 1.0–1.25 all give PF 1.86–2.16.
- Spread doubled to $0.60 (stress test): still PF 1.92 — the edge is not a
  cost artifact.
- ~2–3 trades per week, all inside the London-PM/New-York window.

At 1% account risk per trade, +46R over 13 months ≈ +46% before compounding,
with ~4% peak drawdown. At 2% risk ≈ +90%+ compounded, ~8% drawdown.

## Secondary: 3m settings (validated, weaker)

`swing_len=8, rr_mult=1.5, stop_atr_mult=0.5, ema_len=200, session=12–17 UTC,
break_mode=choch, min_risk_spread_mult=3`

| Window | Trades | Win rate | Profit factor | Avg R | Total R | Max DD (R) |
|---|---|---|---|---|---|---|
| Train | 97 | 48.5% | 1.35 | +0.19 | +18.1 | 8.0 |
| Validation | 22 | 54.6% | 1.79 | +0.36 | +7.9 | 4.0 |
| Full 13 months | 120 | 49.2% | 1.40 | +0.21 | +25.0 | 8.0 |

## Honest caveats — read before trading

1. **One year, one regime.** 2025–26 was a strong gold bull run ($3.3k→$5.6k
   peak). The EMA-200 filter made most trades longs. A flat or bear year may
   behave differently. Re-run the optimizer when conditions change
   (`python3 backtester/smc_backtest.py optimize-all`).
2. **Feed differences.** Your broker's spread, session gaps and slippage
   differ from the reference feed. Export your own M1 data with
   `MQL5/Scripts/ExportRatesCSV.mq5`, drop it at
   `backtester/data/XAUUSD_M1.csv` and re-run to confirm on your feed.
3. **~130 trades is a moderate sample.** The validation window agreeing with
   training is the strongest signal here, but it is 3 months, not 3 years.
4. **No 85%+ win-rate fantasy.** 69–74% at 1:1 R with PF > 2 is what a real,
   cost-inclusive edge looks like. Anyone promising more on M3–M15 gold is
   selling repaint screenshots.
5. Session times are **UTC** (12–17 UTC = London afternoon + NY morning).
   Mind your broker/chart timezone.

## Reproduce

```bash
# summary stats + monthly table for the primary profile
python3 backtester/smc_backtest.py backtest --tf 15min \
  --param swing_len=4 --param rr_mult=1.0 --param stop_atr_mult=0.5 \
  --param ema_len=200 --param session=12-17 --param min_risk_spread_mult=3

# full grid search with train/validation split
python3 backtester/smc_backtest.py optimize-all --param min_risk_spread_mult=3
```

Raw grid results: `backtester/optimize_results.json`.
