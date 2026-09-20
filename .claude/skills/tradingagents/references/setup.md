# TradingAgents — install, keys, providers

Upstream: <https://github.com/TauricResearch/TradingAgents> (v0.5.0, Python ≥3.10,
3.12 recommended). Apache-style research licence — check `LICENSE` in the clone.

## Install

```bash
git clone https://github.com/TauricResearch/TradingAgents.git
cd TradingAgents

# uv
uv venv --python 3.12 && source .venv/bin/activate && uv pip install .

# conda
conda create -n tradingagents python=3.12 && conda activate tradingagents && pip install .
```

Extras: `pip install ".[bedrock]"` (AWS Bedrock), `pip install ".[dev]"`
(ruff + pytest). Entry point after install: `tradingagents`; from a source tree,
`python -m cli.main`.

## Docker

```bash
cp .env.example .env      # fill in keys
docker compose run --rm tradingagents
docker compose build      # after pulling updates
docker compose --profile ollama run --rm tradingagents-ollama   # local models
```

## API keys

Set only the provider you actually use. Put them in `.env` (never commit) or the
environment.

| Var | Provider |
|---|---|
| `OPENAI_API_KEY` | OpenAI (GPT) |
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `GOOGLE_API_KEY` | Google (Gemini) |
| `XAI_API_KEY` | xAI (Grok) |
| `DEEPSEEK_API_KEY` | DeepSeek |
| `DASHSCOPE_API_KEY` / `DASHSCOPE_CN_API_KEY` | Qwen intl / China |
| `ZHIPU_API_KEY` / `ZHIPU_CN_API_KEY` | GLM via Z.AI / BigModel |
| `MINIMAX_API_KEY` / `MINIMAX_CN_API_KEY` | MiniMax global / China |
| `OPENROUTER_API_KEY` | OpenRouter |
| `MISTRAL_API_KEY` | Mistral |
| `MOONSHOT_API_KEY` | Kimi (Moonshot) |
| `GROQ_API_KEY` | Groq |
| `NVIDIA_API_KEY` | NVIDIA NIM |
| `ALPHA_VANTAGE_API_KEY` | Alpha Vantage data vendor |
| `FRED_API_KEY` | FRED macro data (free) |
| `SEC_EDGAR_USER_AGENT` | `"Your Name you@example.com"` — SEC refuses anonymous callers |

Enterprise/local:

- **Azure OpenAI** — copy `.env.enterprise.example` → `.env.enterprise`, fill in.
- **AWS Bedrock** — `llm_provider: "bedrock"`, standard AWS credentials +
  `AWS_DEFAULT_REGION`, Bedrock model IDs (`us.anthropic.claude-opus-4-8-v1:0`).
- **Ollama** — `llm_provider: "ollama"`, default `http://localhost:11434/v1`,
  remote via `OLLAMA_BASE_URL`; `ollama pull <name>` first.
- **Any OpenAI-compatible server** (vLLM, LM Studio, llama.cpp, a relay) —
  `llm_provider: "openai_compatible"` plus `backend_url`
  (`http://localhost:8000/v1`, `http://localhost:1234/v1`);
  `OPENAI_COMPATIBLE_API_KEY` only if the endpoint demands one.

## CLI

```bash
tradingagents                            # interactive: ticker, date, provider, depth
tradingagents --checkpoint               # resume a crashed run
tradingagents --clear-checkpoints        # wipe saved checkpoints first
tradingagents --portfolio my_book.json   # run against a real book
tradingagents backtest NVDA,AAPL --start 2026-06-01 --end 2026-08-01 --every 7
```

The CLI remembers the previous run's answers as defaults; any `TRADINGAGENTS_*`
var set in `.env` skips its prompt entirely.

## Tickers

Yahoo Finance symbology, exchange suffix included. Company identity and the
alpha benchmark resolve per market automatically.

- US `AAPL`, `SPY` · Hong Kong `0700.HK` · Tokyo `7203.T` · London `AZN.L`
- India `RELIANCE.NS` / `.BO` · Canada `.TO` · Australia `.AX`
- China A-shares `600519.SS`, `.SZ` · Crypto `BTC-USD`, `ETH-USD`

## Troubleshooting

- **Run aborts on 429s** — raise `llm_max_retries` (config or
  `TRADINGAGENTS_LLM_MAX_RETRIES`).
- **Run hangs / gateway idle timeout** — some deployments emit unbounded
  reasoning; set `max_tokens`.
- **Malformed request URLs after switching provider** — a stale `backend_url`
  from another provider; set it to `None` unless you need a custom endpoint.
- **Fundamentals missing for a non-US listing** — `sec_edgar` only covers SEC
  filers; chain a fallback: `"sec_edgar,yfinance"`. EDGAR data starts in 2009
  and never derives Q4.
- **Bad env value** — `TRADINGAGENTS_*` vars are type-coerced and raise at
  startup on a misspelled boolean or non-numeric int, by design.
