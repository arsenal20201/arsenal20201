#!/usr/bin/env python3
"""Non-interactive TradingAgents run.

Wraps ``TradingAgentsGraph.propagate`` so a single ticker/date analysis can be
scripted without the interactive CLI. Requires the ``tradingagents`` package on
the path (``pip install .`` in a TradingAgents checkout) and the API key for the
chosen provider in the environment.

Examples
--------
    python run_analysis.py NVDA --date 2026-09-01
    python run_analysis.py 0700.HK --analysts market,news --provider anthropic \
        --deep-model claude-opus-5 --quick-model claude-haiku-4-5-20251001
    python run_analysis.py BTC-USD --asset-type crypto --json

Research output only. Not financial advice, and it places no orders.
"""

import argparse
import json
import sys
from datetime import date


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("ticker", help="Yahoo Finance symbol, e.g. NVDA, 0700.HK, BTC-USD")
    p.add_argument("--date", default=date.today().isoformat(),
                   help="Analysis date YYYY-MM-DD (default: today)")
    p.add_argument("--analysts", default="market,news",
                   help="Comma-separated subset of market,social,news,fundamentals")
    p.add_argument("--asset-type", default="stock", choices=["stock", "crypto"])
    p.add_argument("--provider", help="Override config llm_provider")
    p.add_argument("--deep-model", help="Override deep_think_llm")
    p.add_argument("--quick-model", help="Override quick_think_llm")
    p.add_argument("--backend-url", help="Override backend_url (openai_compatible, remote ollama)")
    p.add_argument("--debate-rounds", type=int, help="Override max_debate_rounds")
    p.add_argument("--risk-rounds", type=int, help="Override max_risk_discuss_rounds")
    p.add_argument("--portfolio", help="Path to a portfolio JSON file")
    p.add_argument("--checkpoint", action="store_true",
                   help="Enable checkpoint resume for this run")
    p.add_argument("--json", action="store_true",
                   help="Print a JSON object instead of a human summary")
    p.add_argument("--debug", action="store_true", help="Stream agent progress")
    return p.parse_args(argv)


def build_config(args):
    from tradingagents.default_config import DEFAULT_CONFIG

    config = DEFAULT_CONFIG.copy()
    overrides = {
        "llm_provider": args.provider,
        "deep_think_llm": args.deep_model,
        "quick_think_llm": args.quick_model,
        "backend_url": args.backend_url,
        "max_debate_rounds": args.debate_rounds,
        "max_risk_discuss_rounds": args.risk_rounds,
    }
    config.update({k: v for k, v in overrides.items() if v is not None})
    if args.checkpoint:
        config["checkpoint_enabled"] = True
    return config


def load_portfolio(path):
    if not path:
        return None
    from tradingagents.portfolio import PortfolioContext

    with open(path, encoding="utf-8") as fh:
        return PortfolioContext.model_validate(json.load(fh))


def main(argv=None):
    args = parse_args(argv)

    try:
        from tradingagents.agents.utils.rating import is_review
        from tradingagents.graph.trading_graph import TradingAgentsGraph
    except ImportError as exc:  # pragma: no cover - environment problem, not logic
        sys.exit(f"tradingagents is not importable ({exc}). "
                 "Install it first: pip install . in a TradingAgents checkout.")

    analysts = [a.strip() for a in args.analysts.split(",") if a.strip()]
    valid = {"market", "social", "news", "fundamentals"}
    unknown = set(analysts) - valid
    if unknown:
        sys.exit(f"Unknown analyst(s): {', '.join(sorted(unknown))}. "
                 f"Valid: {', '.join(sorted(valid))}")

    graph = TradingAgentsGraph(
        selected_analysts=analysts,
        debug=args.debug,
        config=build_config(args),
    )
    final_state, signal = graph.propagate(
        args.ticker,
        args.date,
        asset_type=args.asset_type,
        portfolio=load_portfolio(args.portfolio),
    )

    decision = final_state.get("final_trade_decision", "") if isinstance(final_state, dict) else ""
    needs_review = is_review(signal)

    if args.json:
        print(json.dumps({
            "ticker": args.ticker,
            "date": args.date,
            "analysts": analysts,
            "rating": signal,
            "needs_review": needs_review,
            "decision": decision,
        }, indent=2))
    else:
        print(f"{args.ticker} @ {args.date}: {signal}")
        if needs_review:
            print("No parseable rating — this is NOT a Hold. Re-run or read the "
                  "decision text below by hand.")
        if decision:
            print("\n--- final decision ---")
            print(decision)

    # Exit 2 signals "ran, but produced nothing actionable".
    return 2 if needs_review else 0


if __name__ == "__main__":
    raise SystemExit(main())
