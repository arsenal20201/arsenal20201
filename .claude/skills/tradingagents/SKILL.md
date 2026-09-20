---
name: tradingagents
description: Run and extend TradingAgents (TauricResearch), the multi-agent LLM financial trading framework built on LangGraph. Use when the user wants an LLM-driven analyst/researcher/trader/risk pipeline over a ticker, asks to install, configure, run, backtest, or debug TradingAgents, wants to pick LLM providers or data vendors for it, or wants to combine its Buy/Hold/Sell ratings with this repo's MT5 Expert Advisor.
---

# TradingAgents

Multi-agent trading research framework from Tauric Research
(<https://github.com/TauricResearch/TradingAgents>, arXiv:2412.20138). Specialized
LLM agents — analysts, bull/bear researchers, a trader, a risk team and a portfolio
manager — debate their way to a single 5-tier rating for one ticker on one date.

It is a **research scaffold, not a trading system**. It produces opinions from
LLM reasoning over public data; it does not place orders, and the authors state
plainly it is not financial advice. Never present its output to the user as a
prediction or a recommendation to trade real money.

## When to use this skill

- Installing, configuring, or running TradingAgents (CLI or Python API).
- Choosing an LLM provider/model pair or a data vendor chain for it.
- Reading or explaining its agent graph, reports, decision log, or backtests.
- Wiring its ratings into something else — including the `HighWinRateEA` MT5
  Expert Advisor in this repo (see "Bridging to the MT5 EA" below).

## Quick start

```bash
git clone https://github.com/TauricResearch/TradingAgents.git
cd TradingAgents
uv venv --python 3.12 && source .venv/bin/activate   # or conda
uv pip install .                                      # or: pip install .

export OPENAI_API_KEY=...        # or the key for whichever provider you pick
export ANTHROPIC_API_KEY=...     # for llm_provider="anthropic"

tradingagents                     # interactive CLI (or: python -m cli.main)
```

Programmatic run:

```python
from tradingagents.graph.trading_graph import TradingAgentsGraph
from tradingagents.default_config import DEFAULT_CONFIG

config = DEFAULT_CONFIG.copy()
config["llm_provider"] = "anthropic"
config["deep_think_llm"] = "claude-opus-5"     # heavy reasoning nodes
config["quick_think_llm"] = "claude-haiku-4-5-20251001"  # analyst/tool nodes
config["max_debate_rounds"] = 1

ta = TradingAgentsGraph(
    selected_analysts=["market", "news"],       # subset = cheaper, faster
    debug=True,
    config=config,
)
final_state, signal = ta.propagate("NVDA", "2026-09-01")
print(signal)   # Buy | Overweight | Hold | Underweight | Sell | REVIEW
```

`scripts/run_analysis.py` in this skill wraps that in a non-interactive CLI —
copy it into a TradingAgents checkout (or run it with the package installed).

## Working rules

1. **Cost before runs.** A full four-analyst run with debate rounds is many LLM
   calls. Before running one for a user, say roughly what it will cost and
   offer the cheap shape first: `selected_analysts=["market"]`,
   `max_debate_rounds=1`, a small `quick_think_llm`.
2. **Never invent output.** If a run was not executed (no API key, no network),
   say so — do not narrate a plausible analyst report or rating.
3. **`REVIEW` is not `Hold`.** `propagate` returns `"REVIEW"` when no rating
   could be parsed. Guard with `tradingagents.agents.utils.rating.is_review`
   before mapping to a position; treat it as "needs a human or a re-run".
4. **Dates are point-in-time.** A past `trade_date` pins prices, indicators and
   (via `sec_edgar`) fundamentals as filed — but news/social sources still
   reflect now. Say that when a user reads a historical run as a clean backtest.
5. **Runs are not reproducible.** Same ticker + same date ≠ same answer.
   Reasoning models largely ignore `temperature`. Never promise repeatability.
6. **One run proves nothing.** If the user asks whether it "works", point at
   `run_backtest` over a ticker/date grid scored on realized alpha, not at a
   single decision.
7. **Keep keys out of the repo.** Keys go in `.env` (gitignored) or the
   environment — never in committed config, code, or a PR body.

## Configuration map

`DEFAULT_CONFIG` lives in `tradingagents/default_config.py`. Most-used keys:

| Key | Default | Notes |
|---|---|---|
| `llm_provider` | `"openai"` | `openai`, `anthropic`, `google`, `xai`, `deepseek`, `qwen`, `glm`, `minimax`, `openrouter`, `mistral`, `moonshot`, `groq`, `nvidia`, `bedrock`, `ollama`, `openai_compatible` |
| `deep_think_llm` | `"gpt-5.6"` | Research manager, trader, risk, portfolio manager |
| `quick_think_llm` | `"gpt-5.6-luna"` | Analysts and tool-calling nodes |
| `backend_url` | `None` | Set for `openai_compatible` / remote Ollama |
| `max_debate_rounds` | `1` | Bull vs bear rounds |
| `max_risk_discuss_rounds` | `1` | Aggressive/conservative/neutral rounds |
| `output_language` | `"English"` | Reports only; internal debate stays English |
| `checkpoint_enabled` | `False` | Resume a crashed run (`--checkpoint`) |
| `holding_period_days` | `5` | Window used to score a decision |
| `data_vendors` | see below | Exact vendor chain, no silent fallback |
| `temperature` / `max_tokens` / `llm_max_retries` | `None` | Provider defaults |

Every key in the `TRADINGAGENTS_*` env map (top of `default_config.py`) can be
set from `.env` instead of code — `TRADINGAGENTS_LLM_PROVIDER`,
`TRADINGAGENTS_DEEP_THINK_LLM`, `TRADINGAGENTS_MAX_DEBATE_ROUNDS`, and so on.

Data vendors (`config["data_vendors"]`), all default to a single vendor:
`core_stock_apis`, `technical_indicators`, `fundamental_data` (add
`"sec_edgar,yfinance"` for as-filed US fundamentals), `news_data`, `macro_data`
(`fred`, needs `FRED_API_KEY`), `prediction_markets` (`polymarket`, keyless).

Full detail: `references/setup.md` (install, keys, providers, Docker),
`references/api.md` (Python API, portfolio, backtest, persistence),
`references/agents.md` (graph shape, each agent's job, rating scale).

## Bridging to the MT5 EA

This repo's `MQL5/Experts/HighWinRateEA.mq5` is a mechanical trend-pullback EA;
TradingAgents is a slow, discretionary-style research layer. They compose in one
direction only:

- **Sane:** use a TradingAgents rating as a *directional filter* — e.g. refuse
  long entries while the standing rating is `Underweight`/`Sell` — written to a
  file or global variable the EA reads. Keep the EA's own risk controls intact.
- **Not sane:** letting an LLM set lot size, stop distance, or the daily loss
  limit, or firing a trade per run. Position sizing and the daily loss limit are
  what keep the account alive (see the repo README); they stay mechanical.
- Timeframes differ by orders of magnitude: the EA acts per closed M30/H1 bar,
  a TradingAgents run takes minutes and is dated to a day. Treat a rating as a
  daily bias, never an entry trigger.
- Coverage differs too: TradingAgents resolves tickers through Yahoo Finance
  (`AAPL`, `0700.HK`, `BTC-USD`); FX pairs and CFD symbols the EA trades are not
  first-class there. Map the symbol explicitly, or don't wire them at all.

Always pair any such bridge with demo-account testing before live use.
