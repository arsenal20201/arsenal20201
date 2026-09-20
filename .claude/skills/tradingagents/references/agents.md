# TradingAgents — agent graph

Built on LangGraph. One run = one ticker, one date, one rating.

```
Analyst team  →  Researcher debate  →  Trader  →  Risk team  →  Portfolio manager
```

## Analyst team (`quick_think_llm`)

Each writes an independent report into the shared state.

- **Market / technical** (`market`) — indicators (MACD, RSI, …) over the price
  window; exact price and indicator claims are grounded in a verified snapshot
  rather than recalled.
- **Sentiment** (`social`) — news headlines, StockTwits and Reddit folded into a
  short-term mood read.
- **News** (`news`) — global headlines and macro indicators (FRED) and what they
  imply for the instrument.
- **Fundamentals** (`fundamentals`) — financial statements and performance
  metrics; with the `sec_edgar` vendor, as filed on the analysis date.

## Researcher team (`deep_think_llm`)

Bull and bear researchers argue over the analyst reports for
`max_debate_rounds` rounds. The **research manager** closes the debate with an
investment plan carrying a 5-tier recommendation.

## Trader

Turns the reports and the investment plan into a concrete proposal — direction
and magnitude — grounded in the current price. With a `PortfolioContext` it
works against the actual book instead of a generic reader.

## Risk team + portfolio manager

Aggressive, conservative and neutral risk debators stress the proposal for
`max_risk_discuss_rounds` rounds across volatility, liquidity and exposure. The
**portfolio manager** approves or rejects and issues the final decision; in the
simulation an approved order goes to a simulated exchange. Its prompt also
carries the reflection memory: recent same-ticker decisions with their realized
alpha, plus cross-ticker lessons.

## Rating scale

Single 5-tier vocabulary shared by the research manager, the portfolio manager,
the signal processor and the memory log
(`tradingagents/agents/utils/rating.py`):

```
Buy  >  Overweight  >  Hold  >  Underweight  >  Sell
```

plus `REVIEW` when nothing parseable was produced. `extract_rating` reads an
explicit `Rating: X` label first (tolerating markdown bold, unicode dashes and
fullwidth punctuation), then falls back to the first standalone rating word;
lines presenting the scale itself are ignored. `REVIEW` deliberately does not
collapse to `Hold` — a decision nobody can read is not a decision.

## Cost levers, cheapest first

1. Fewer `selected_analysts` (one analyst ≈ a quarter of the analyst stage).
2. `max_debate_rounds` / `max_risk_discuss_rounds` at 1.
3. A small `quick_think_llm` — it drives the tool-calling analyst nodes, which
   dominate call count.
4. Lower `news_article_limit` / `global_news_article_limit` to shrink prompts.
5. Reserve the expensive `deep_think_llm` for the manager/trader/risk nodes,
   which is already the split the config intends.
