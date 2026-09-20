# TradingAgents — Python API

## Graph

```python
from tradingagents.graph.trading_graph import TradingAgentsGraph
from tradingagents.default_config import DEFAULT_CONFIG

ta = TradingAgentsGraph(
    selected_analysts=("market", "social", "news", "fundamentals"),  # default
    debug=False,
    config=DEFAULT_CONFIG.copy(),
)
final_state, signal = ta.propagate("NVDA", "2026-09-01")
```

`propagate(company_name, trade_date, asset_type="stock", portfolio=None)` returns
`(final_state, signal)`.

- `signal` ∈ `Buy | Overweight | Hold | Underweight | Sell | REVIEW`.
- `REVIEW` means no rating could be parsed — not a position. Guard with
  `from tradingagents.agents.utils.rating import is_review` before mapping onto
  `PortfolioRating(signal)`.
- `final_state` carries each analyst's report, the debate transcripts, the
  investment plan and the final decision text.
- `asset_type="crypto"` selects the crypto pipeline; the CLI auto-detects it
  from the ticker, programmatic callers pass it.
- `trade_date` is validated (`YYYY-MM-DD`).

Analyst keys: `market` (technical), `social` (sentiment), `news`,
`fundamentals`. Dropping analysts is the cheapest lever on cost and latency.

## Current holdings

Without a portfolio the agents write for an unknown reader — and a run with no
portfolio is *not* treated as a flat book.

```python
from tradingagents.portfolio import PortfolioContext

portfolio = PortfolioContext.model_validate({
    "cash": 25000.0,
    "currency": "USD",
    "positions": [{"ticker": "NVDA", "quantity": 120, "average_price": 150.0}],
})
_, decision = ta.propagate("NVDA", "2026-09-01", portfolio=portfolio)
```

An empty `positions` list *does* mean flat. CLI equivalent: `--portfolio book.json`.

## Persistence

**Decision log** (always on): every completed run appends to
`~/.tradingagents/memory/trading_memory.md` (`TRADINGAGENTS_MEMORY_LOG_PATH`).
The next run for the same ticker fetches the realized return and alpha vs the
instrument's regional benchmark, writes a one-paragraph reflection, and injects
recent same-ticker decisions plus cross-ticker lessons into the portfolio
manager's prompt. `memory_log_max_entries` rotates resolved entries; pending
entries are never pruned.

**Checkpoint resume** (opt-in): `config["checkpoint_enabled"] = True` or
`--checkpoint`. LangGraph saves state per node into
`~/.tradingagents/cache/checkpoints/<TICKER>.db` (`TRADINGAGENTS_CACHE_DIR`), and
checkpoints clear on success. `--clear-checkpoints` resets them. Resume is keyed
on ticker + date + a run signature covering analysts and portfolio, so changing
the graph shape starts fresh rather than resuming a mismatched state.

## Backtesting

```python
from tradingagents.backtest import iter_grid, run_backtest, summarize
from tradingagents.agents.utils.memory import TradingMemoryLog

dates = iter_grid("2026-06-01", "2026-08-01", every_n_days=7)
result = run_backtest(["NVDA", "AAPL"], dates, config, selected_analysts=["market", "news"])
print(summarize(TradingMemoryLog({"memory_log_path": str(result.log_path)})).render())
```

- Writes to its own decision log — your personal log is untouched.
- Cells are scored on realized alpha vs the regional benchmark over
  `holding_period_days` (default 5 trading days), grouped by rating.
- Re-running with `run_id=result.run_id` skips completed cells, so an
  interrupted sweep continues.
- CLI: `tradingagents backtest NVDA,AAPL --start ... --end ... --every 7
  [--analysts market,news] [--asset-type crypto] [--portfolio book.json]`.

Cost scales as tickers × dates × agents. Price a grid before launching it.

## Point-in-time and reproducibility

A dated run reads prices and indicators as of that date, and with
`data_vendors["fundamental_data"] = "sec_edgar,yfinance"` reads US statements as
*filed* — a later restatement does not leak backwards (Apple's 2008 total assets
read $39.6B for a run dated before the 2010 restatement to $36.2B). News,
StockTwits and Reddit still reflect now, so a dated run is not a clean backtest.

Output varies run to run: providers do not guarantee identical output, reasoning
models sample their own reasoning, and live sources move. `temperature` (or
`TRADINGAGENTS_TEMPERATURE`) helps only on models that honor it — name a
non-reasoning model for tighter repeatability. What *is* deterministic: company
identity resolved from the ticker before any agent runs, and the market analyst's
price/indicator claims grounded in a verified snapshot.
