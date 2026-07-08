---
name: run-backtester
description: Run, backtest, optimize or re-validate the XAUUSD SMC scalping strategy offline — fetch market data, run backtester/smc_backtest.py backtests, grid-search settings, and reproduce the numbers in backtester/BACKTEST_REPORT.md.
---

# Run the SMC strategy backtester

Offline backtester for the Pine strategy in `PineScript/smc_confluence_strategy.pine`.
The driver is `backtester/smc_backtest.py` (a CLI — no GUI, no server). All
paths below are relative to the repo root. Every command here was run and
verified in a Claude remote container.

## Prerequisites

```bash
pip install pandas numpy pyarrow
```

## Data (required first)

The backtester needs `backtester/data/XAUUSD_M1.csv.gz`. If it is missing:

- **Preferred:** trigger the `Fetch XAUUSD historical data` GitHub Actions
  workflow (`.github/workflows/fetch-data.yml`) and `git pull` after it
  pushes the data commit. It must run on GitHub's runners because the Claude
  container's proxy blocks all market-data hosts (Dukascopy, Binance, Yahoo,
  HuggingFace all return CONNECT 403 — only raw.githubusercontent.com and
  package registries pass).
- **Alternative:** an MT5 export from `MQL5/Scripts/ExportRatesCSV.mq5`
  placed at `backtester/data/XAUUSD_M1.csv` (the loader accepts MT5
  `YYYY.MM.DD HH:MM` timestamps and plain or gzipped CSV).

## Run a backtest (agent path)

```bash
# tuned 15m profile — should print ~130 trades, ~69% win rate, PF ~2.1
python3 backtester/smc_backtest.py backtest --tf 15min \
  --param swing_len=4 --param rr_mult=1.0 --param stop_atr_mult=0.5 \
  --param ema_len=200 --param session=12-17 --param min_risk_spread_mult=3

# write the individual trades to CSV
python3 backtester/smc_backtest.py backtest --tf 15min --trades-out /tmp/trades.csv
```

`--tf` takes pandas offsets (`3min`, `5min`, `15min`). `--param key=value`
overrides any field of `Params` (see the dataclass at the top of the driver).

## Optimize

```bash
# one timeframe, 216-combo grid, train/validation split at --split
python3 backtester/smc_backtest.py optimize --tf 15min --split 2026-04-01

# all three timeframes; writes backtester/optimize_results.json (takes ~10 min)
python3 backtester/smc_backtest.py optimize-all --param min_risk_spread_mult=3
```

Judge results by the `valid` block (out-of-sample), not `train`. A config
whose validation profit factor collapses below 1 is curve-fit — that is
exactly how 5m failed while 15m survived (see `backtester/BACKTEST_REPORT.md`).

## Gotchas

- **Dukascopy blocks GitHub runner IPs** (all-day read timeouts). The fetch
  script auto-falls back to HistData.com. HistData quirk: past years must be
  downloaded as ONE yearly zip (`month=None`), current-year months
  individually; its timestamps are fixed UTC-5 (no DST) and the fetcher
  shifts them to UTC.
- The fetch workflow triggers on push to its own paths; `workflow_dispatch`
  only works after the workflow file exists on the repo's default branch.
  It rebases before pushing data because the branch usually moves during
  the ~10 min download.
- Session filters and all timestamps are **UTC**.
- A stop-hook rejects untracked files: `backtester/optimize_log.txt` and
  `__pycache__/` are gitignored for that reason.
- Engine conventions: fills at next bar open, bid/ask spread + slippage
  charged, stop fills before target on ambiguous bars, force-flat Friday
  20:30 UTC. Results are deliberately more conservative than TradingView's
  tester.

## Test

No unit suite; the smoke test is the tuned-profile backtest above printing
stats and a monthly table in ~1–2 s without a traceback.
