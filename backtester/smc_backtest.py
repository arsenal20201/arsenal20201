#!/usr/bin/env python3
"""
SMC Confluence Scalper — offline backtester and optimizer for XAUUSD.

Faithful Python port of PineScript/smc_confluence_strategy.pine:

  1. Internal swing detection (LuxAlgo-style, confirmed `swing_len` bars
     after the extreme).
  2. Structure break: close crosses the last swing level (CHoCH/BOS).
  3. Order block = last opposite candle before the break.
  4. Entry: pullback into the zone + confirmed close back beyond its edge.
  5. Filters: EMA trend, RSI, session window (UTC).
  6. Risk: ATR-buffered stop beyond the zone, take-profit at R multiple.

Execution model (more conservative than TradingView's tester):
  * Signals are evaluated on closed bars; fills happen at the NEXT bar open.
  * Data is BID candles. Longs buy at ask (bid+spread), sell at bid;
    shorts sell at bid, cover at ask.
  * Slippage is added on entries and stop exits.
  * If a bar touches both stop and target, the STOP is assumed first.
  * Positions are force-closed before the weekend (Friday 20:30 UTC).

Usage:
  python3 backtester/smc_backtest.py backtest --tf 5min [--param x=y ...]
  python3 backtester/smc_backtest.py optimize --tf 5min
  python3 backtester/smc_backtest.py optimize-all

Data: backtester/data/XAUUSD_M1.csv.gz (dukascopy-node CSV: timestamp-ms,
open, high, low, close, volume). Fetched by .github/workflows/fetch-data.yml.
"""

from __future__ import annotations

import argparse
import gzip
import itertools
import json
import math
import os
import sys
from dataclasses import dataclass, field, asdict, replace

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_FILE = os.path.join(HERE, "data", "XAUUSD_M1.csv.gz")

# ----------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------

@dataclass(frozen=True)
class Params:
    swing_len: int = 5          # bars each side to confirm internal swing
    ob_lookback: int = 25       # bars to search for the order-block candle
    zone_timeout: int = 40      # bars before an untested zone expires
    ema_len: int = 200          # 0 disables the EMA trend filter
    rsi_len: int = 0            # 0 disables the RSI filter
    atr_len: int = 14
    stop_atr_mult: float = 0.5  # stop buffer beyond zone edge, in ATRs
    rr_mult: float = 1.5        # take-profit at rr_mult * risk
    session: str = "all"        # "all" | "HH-HH" UTC entry window, e.g. "07-17"
    allow_longs: bool = True
    allow_shorts: bool = True
    break_mode: str = "all"     # "all" | "choch" (reversals only) | "bos"
    breakeven: bool = False     # move stop to entry once +1R is reached
    zone_min_atr: float = 0.0   # reject zones thinner than this (× ATR)
    zone_max_atr: float = 10.0  # reject zones taller than this (× ATR)
    min_risk_spread_mult: float = 0.0  # require risk >= this × spread
    # execution costs (price units, i.e. USD per oz for XAUUSD)
    spread: float = 0.30        # full bid/ask spread
    slippage: float = 0.05      # extra cost on entry and stop exits

    def session_hours(self):
        if self.session == "all":
            return None
        a, b = self.session.split("-")
        return int(a), int(b)


@dataclass
class Trade:
    direction: int              # +1 long, -1 short
    entry_time: pd.Timestamp
    entry: float
    stop: float                 # current stop (may move to breakeven)
    target: float
    init_risk: float            # risk at entry — R denominator stays fixed
    exit_time: pd.Timestamp | None = None
    exit: float | None = None
    reason: str = ""            # "tp" | "stop" | "be" | "week_end" | "eod"

    @property
    def pnl(self) -> float:
        return (self.exit - self.entry) * self.direction

    @property
    def r_multiple(self) -> float:
        return self.pnl / self.init_risk if self.init_risk > 0 else 0.0


# ----------------------------------------------------------------------------
# Data loading
# ----------------------------------------------------------------------------

def load_m1(path: str = DATA_FILE) -> pd.DataFrame:
    if not os.path.exists(path):
        sys.exit(
            f"Data file not found: {path}\n"
            "Run the 'Fetch XAUUSD historical data' GitHub Actions workflow "
            "(.github/workflows/fetch-data.yml) and pull the branch, or place "
            "an MT5 export there (see MQL5/Scripts/ExportRatesCSV.mq5)."
        )
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt") as fh:
        first = fh.readline()
    header = 0 if any(c.isalpha() for c in first) else None
    df = pd.read_csv(path, header=header)
    df.columns = ["timestamp", "open", "high", "low", "close", "volume"][: len(df.columns)]
    # dukascopy-node timestamps are epoch milliseconds (UTC);
    # MT5 exports use 'YYYY.MM.DD HH:MM' strings — support both.
    if pd.api.types.is_numeric_dtype(df["timestamp"]):
        idx = pd.to_datetime(df["timestamp"], unit="ms", utc=True)
    else:
        idx = pd.to_datetime(
            df["timestamp"].astype(str).str.replace(".", "-", regex=False), utc=True)
    df.index = idx.dt.tz_convert("UTC").dt.tz_localize(None)
    df = df[["open", "high", "low", "close", "volume"]].astype(float)
    df = df[~df.index.duplicated(keep="first")].sort_index()
    # drop zero-range dead bars (weekend placeholders in some feeds)
    df = df[(df["high"] > 0) & (df["high"] >= df["low"])]
    return df


def resample(m1: pd.DataFrame, tf: str) -> pd.DataFrame:
    o = m1["open"].resample(tf).first()
    h = m1["high"].resample(tf).max()
    l = m1["low"].resample(tf).min()
    c = m1["close"].resample(tf).last()
    v = m1["volume"].resample(tf).sum()
    df = pd.DataFrame({"open": o, "high": h, "low": l, "close": c, "volume": v}).dropna()
    return df


# ----------------------------------------------------------------------------
# Indicators
# ----------------------------------------------------------------------------

def ema(series: np.ndarray, length: int) -> np.ndarray:
    out = np.full_like(series, np.nan, dtype=float)
    alpha = 2.0 / (length + 1.0)
    prev = series[0]
    for i, x in enumerate(series):
        prev = x if i == 0 else alpha * x + (1 - alpha) * prev
        out[i] = prev
    return out


def rma(series: np.ndarray, length: int) -> np.ndarray:
    out = np.full_like(series, np.nan, dtype=float)
    alpha = 1.0 / length
    prev = np.nanmean(series[:length]) if len(series) >= length else np.nan
    for i, x in enumerate(series):
        if i < length:
            out[i] = np.nan
            continue
        prev = alpha * x + (1 - alpha) * (out[i - 1] if not math.isnan(out[i - 1]) else prev)
        out[i] = prev
    # seed
    if len(series) >= length:
        out[length - 1] = np.mean(series[:length])
        for i in range(length, len(series)):
            out[i] = alpha * series[i] + (1 - alpha) * out[i - 1]
    return out


def atr(df: pd.DataFrame, length: int) -> np.ndarray:
    h, l, c = df["high"].values, df["low"].values, df["close"].values
    prev_c = np.roll(c, 1)
    prev_c[0] = c[0]
    tr = np.maximum(h - l, np.maximum(np.abs(h - prev_c), np.abs(l - prev_c)))
    return rma(tr, length)


def rsi(close: np.ndarray, length: int) -> np.ndarray:
    delta = np.diff(close, prepend=close[0])
    up = np.clip(delta, 0, None)
    dn = np.clip(-delta, 0, None)
    ru = rma(up, length)
    rd = rma(dn, length)
    with np.errstate(divide="ignore", invalid="ignore"):
        rs = ru / rd
        out = 100 - 100 / (1 + rs)
    out[np.isnan(rd) | (rd == 0)] = 100.0
    out[np.isnan(ru)] = np.nan
    return out


def swings(df: pd.DataFrame, length: int):
    """LuxAlgo swings(): returns (new_top, new_btm, top_level, btm_level)
    arrays. new_top[t] True means a swing high (value top_level[t] =
    high[t-length]) was CONFIRMED at bar t."""
    h, l = df["high"].values, df["low"].values
    n = len(df)
    roll_max = pd.Series(h).rolling(length).max().values
    roll_min = pd.Series(l).rolling(length).min().values
    os_arr = np.zeros(n, dtype=int)
    new_top = np.zeros(n, dtype=bool)
    new_btm = np.zeros(n, dtype=bool)
    top_level = np.full(n, np.nan)
    btm_level = np.full(n, np.nan)
    prev_os = 0
    for t in range(n):
        if t < length or math.isnan(roll_max[t]):
            os_arr[t] = prev_os
            continue
        ref_hi = h[t - length]
        ref_lo = l[t - length]
        cur = 0 if ref_hi > roll_max[t] else (1 if ref_lo < roll_min[t] else prev_os)
        os_arr[t] = cur
        if cur == 0 and prev_os != 0:
            new_top[t] = True
            top_level[t] = ref_hi
        if cur == 1 and prev_os != 1:
            new_btm[t] = True
            btm_level[t] = ref_lo
        prev_os = cur
    return new_top, new_btm, top_level, btm_level


# ----------------------------------------------------------------------------
# Backtest engine
# ----------------------------------------------------------------------------

def run_backtest(df: pd.DataFrame, p: Params, collect_trades: bool = True):
    """Bar-by-bar simulation. Returns (trades, stats_dict)."""
    o = df["open"].values
    h = df["high"].values
    l = df["low"].values
    c = df["close"].values
    ts = df.index
    n = len(df)

    new_top, new_btm, top_lvl_arr, btm_lvl_arr = swings(df, p.swing_len)
    atr_arr = atr(df, p.atr_len)
    ema_arr = ema(c, p.ema_len) if p.ema_len > 0 else None
    rsi_arr = rsi(c, p.rsi_len) if p.rsi_len > 0 else None
    hours = ts.hour.values
    dows = ts.dayofweek.values  # Mon=0 ... Sun=6
    mins = ts.minute.values
    sess = p.session_hours()

    itrend = 0
    itop_y = math.nan
    ibtm_y = math.nan
    itop_crossed = True
    ibtm_crossed = True
    prev_itop_y = math.nan
    prev_ibtm_y = math.nan

    setup_dir = 0
    zone_top = zone_btm = math.nan
    zone_birth = -1

    pending = None          # (direction, stop_seed_top, stop_seed_btm, atr_at_signal)
    pos: Trade | None = None
    trades: list[Trade] = []

    half_spread = p.spread / 2.0

    warmup = max(p.swing_len * 2, p.atr_len, p.ema_len, p.rsi_len) + 2

    for t in range(n):
        # ------------------------------------------------ manage open position
        if pos is not None:
            exited = False
            # weekend flat: close at this bar's open if Friday >= 20:30 UTC
            if dows[t] == 4 and (hours[t] > 20 or (hours[t] == 20 and mins[t] >= 30)):
                px = o[t] - half_spread * pos.direction
                pos.exit, pos.exit_time, pos.reason = px, ts[t], "week_end"
                exited = True
            if not exited:
                if pos.direction > 0:
                    stop_hit = l[t] <= pos.stop
                    tp_hit = h[t] >= pos.target
                    if stop_hit:  # conservative: stop first
                        px = min(pos.stop, o[t]) - p.slippage
                        reason = "be" if pos.stop >= pos.entry else "stop"
                        pos.exit, pos.exit_time, pos.reason = px, ts[t], reason
                        exited = True
                    elif tp_hit:
                        pos.exit, pos.exit_time, pos.reason = pos.target, ts[t], "tp"
                        exited = True
                    elif p.breakeven and h[t] >= pos.entry + pos.init_risk:
                        pos.stop = max(pos.stop, pos.entry)
                else:
                    stop_hit = h[t] >= pos.stop
                    tp_hit = l[t] <= pos.target
                    if stop_hit:
                        px = max(pos.stop, o[t]) + p.slippage
                        reason = "be" if pos.stop <= pos.entry else "stop"
                        pos.exit, pos.exit_time, pos.reason = px, ts[t], reason
                        exited = True
                    elif tp_hit:
                        pos.exit, pos.exit_time, pos.reason = pos.target, ts[t], "tp"
                        exited = True
                    elif p.breakeven and l[t] <= pos.entry - pos.init_risk:
                        pos.stop = min(pos.stop, pos.entry)
            if exited:
                trades.append(pos)
                pos = None

        # ------------------------------------------------ pending entry fill
        if pending is not None and pos is None:
            direction, z_top, z_btm, atr_sig = pending
            if direction > 0:
                fill = o[t] + half_spread + p.slippage
                stop = z_btm - atr_sig * p.stop_atr_mult
                risk = fill - stop
                if risk > 0 and risk >= p.min_risk_spread_mult * p.spread:
                    pos = Trade(1, ts[t], fill, stop, fill + risk * p.rr_mult, risk)
            else:
                fill = o[t] - half_spread - p.slippage
                stop = z_top + atr_sig * p.stop_atr_mult
                risk = stop - fill
                if risk > 0 and risk >= p.min_risk_spread_mult * p.spread:
                    pos = Trade(-1, ts[t], fill, stop, fill - risk * p.rr_mult, risk)
            pending = None

        if t < warmup:
            prev_itop_y, prev_ibtm_y = itop_y, ibtm_y
            continue

        # ------------------------------------------------ structure update
        if new_top[t]:
            itop_y = top_lvl_arr[t]
            itop_crossed = False
        if new_btm[t]:
            ibtm_y = btm_lvl_arr[t]
            ibtm_crossed = False

        bull_break = (
            not math.isnan(itop_y) and not itop_crossed
            and c[t] > itop_y
            and (math.isnan(prev_itop_y) or c[t - 1] <= prev_itop_y)
        )
        bear_break = (
            not math.isnan(ibtm_y) and not ibtm_crossed
            and c[t] < ibtm_y
            and (math.isnan(prev_ibtm_y) or c[t - 1] >= prev_ibtm_y)
        )
        prev_itop_y, prev_ibtm_y = itop_y, ibtm_y

        if bull_break:
            choch = itrend < 0
            itop_crossed = True
            itrend = 1
            mode_ok = (p.break_mode == "all" or (p.break_mode == "choch") == choch)
            if mode_ok:
                for i in range(1, min(p.ob_lookback, t) + 1):
                    if c[t - i] < o[t - i]:
                        zh = h[t - i] - l[t - i]
                        if p.zone_min_atr * atr_arr[t] <= zh <= p.zone_max_atr * atr_arr[t]:
                            setup_dir, zone_top, zone_btm, zone_birth = 1, h[t - i], l[t - i], t
                        break
        if bear_break:
            choch = itrend > 0
            ibtm_crossed = True
            itrend = -1
            mode_ok = (p.break_mode == "all" or (p.break_mode == "choch") == choch)
            if mode_ok:
                for i in range(1, min(p.ob_lookback, t) + 1):
                    if c[t - i] > o[t - i]:
                        zh = h[t - i] - l[t - i]
                        if p.zone_min_atr * atr_arr[t] <= zh <= p.zone_max_atr * atr_arr[t]:
                            setup_dir, zone_top, zone_btm, zone_birth = -1, h[t - i], l[t - i], t
                        break

        # ------------------------------------------------ zone invalidation
        if setup_dir == 1 and (t - zone_birth > p.zone_timeout or c[t] < zone_btm):
            setup_dir = 0
        if setup_dir == -1 and (t - zone_birth > p.zone_timeout or c[t] > zone_top):
            setup_dir = 0

        # ------------------------------------------------ entry trigger
        if pos is None and pending is None and setup_dir != 0 and t > zone_birth:
            in_sess = True
            if sess is not None:
                a, b = sess
                in_sess = (a <= hours[t] < b) if a < b else (hours[t] >= a or hours[t] < b)
            # no fresh entries into the weekend
            if dows[t] == 4 and hours[t] >= 19:
                in_sess = False
            if in_sess:
                if setup_dir == 1 and p.allow_longs:
                    trig = l[t] <= zone_top and c[t] > zone_top and c[t] > o[t]
                    if trig and (ema_arr is None or c[t] > ema_arr[t]) \
                            and (rsi_arr is None or rsi_arr[t] > 50):
                        pending = (1, zone_top, zone_btm, atr_arr[t])
                        setup_dir = 0
                elif setup_dir == -1 and p.allow_shorts:
                    trig = h[t] >= zone_btm and c[t] < zone_btm and c[t] < o[t]
                    if trig and (ema_arr is None or c[t] < ema_arr[t]) \
                            and (rsi_arr is None or rsi_arr[t] < 50):
                        pending = (-1, zone_top, zone_btm, atr_arr[t])
                        setup_dir = 0

    # close any position at the end of data
    if pos is not None:
        pos.exit = c[-1] - half_spread * pos.direction
        pos.exit_time = ts[-1]
        pos.reason = "eod"
        trades.append(pos)

    return trades, compute_stats(trades)


# ----------------------------------------------------------------------------
# Statistics
# ----------------------------------------------------------------------------

def compute_stats(trades: list[Trade]) -> dict:
    if not trades:
        return {"trades": 0, "win_rate": 0.0, "profit_factor": 0.0,
                "avg_r": 0.0, "total_r": 0.0, "max_dd_r": 0.0,
                "max_consec_losses": 0}
    rs = np.array([tr.r_multiple for tr in trades])
    wins = rs[rs > 0]
    losses = rs[rs <= 0]
    gross_w = wins.sum() if len(wins) else 0.0
    gross_l = -losses.sum() if len(losses) else 0.0
    equity = np.cumsum(rs)
    peak = np.maximum.accumulate(equity)
    dd = (peak - equity).max() if len(equity) else 0.0
    consec = worst = 0
    for r in rs:
        consec = consec + 1 if r <= 0 else 0
        worst = max(worst, consec)
    return {
        "trades": int(len(rs)),
        "win_rate": round(float(len(wins)) / len(rs) * 100, 2),
        "profit_factor": round(float(gross_w / gross_l), 3) if gross_l > 0 else float("inf"),
        "avg_r": round(float(rs.mean()), 4),
        "total_r": round(float(rs.sum()), 2),
        "max_dd_r": round(float(dd), 2),
        "max_consec_losses": int(worst),
    }


def monthly_table(trades: list[Trade]) -> pd.DataFrame:
    if not trades:
        return pd.DataFrame()
    rows = [{"month": tr.exit_time.strftime("%Y-%m"), "r": tr.r_multiple,
             "win": tr.r_multiple > 0} for tr in trades]
    df = pd.DataFrame(rows)
    g = df.groupby("month").agg(trades=("r", "size"), total_r=("r", "sum"),
                                win_rate=("win", "mean"))
    g["total_r"] = g["total_r"].round(2)
    g["win_rate"] = (g["win_rate"] * 100).round(1)
    return g


# ----------------------------------------------------------------------------
# Optimizer
# ----------------------------------------------------------------------------

# Stage-1 grid: 216 combos. Refine winners by hand afterwards (breakeven,
# zone filters, zone_timeout) — a bigger grid here would only curve-fit.
GRID = {
    "swing_len": [4, 5, 8],
    "rr_mult": [1.0, 1.5, 2.0],
    "stop_atr_mult": [0.3, 0.5],
    "ema_len": [0, 200],
    "session": ["all", "07-17", "12-17"],
    "break_mode": ["all", "choch"],
}


def optimize(df: pd.DataFrame, tf: str, split: str, base: Params,
             min_trades: int, top_n: int = 8) -> list[dict]:
    train = df[df.index < split]
    valid = df[df.index >= split]
    keys = list(GRID.keys())
    results = []
    combos = list(itertools.product(*GRID.values()))
    for i, combo in enumerate(combos):
        p = replace(base, **dict(zip(keys, combo)))
        _, st = run_backtest(train, p, collect_trades=False)
        if st["trades"] < min_trades or st["profit_factor"] <= 1.0:
            continue
        # score: expectancy weighted by sample size, penalized by drawdown
        score = st["avg_r"] * math.sqrt(st["trades"]) - 0.02 * st["max_dd_r"]
        results.append({"params": dict(zip(keys, combo)), "train": st, "score": round(score, 4)})
        if (i + 1) % 50 == 0:
            print(f"  ... {i+1}/{len(combos)} combos", file=sys.stderr)
    results.sort(key=lambda r: r["score"], reverse=True)
    finalists = results[:top_n]
    for r in finalists:
        p = replace(base, **r["params"])
        _, vst = run_backtest(valid, p, collect_trades=False)
        r["valid"] = vst
    return finalists


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def parse_overrides(pairs: list[str]) -> dict:
    out = {}
    for pair in pairs or []:
        k, v = pair.split("=", 1)
        fld = Params.__dataclass_fields__.get(k)
        if fld is None:
            sys.exit(f"Unknown param: {k}. Valid: {list(Params.__dataclass_fields__)}")
        typ = fld.type
        if typ in ("int",):
            out[k] = int(v)
        elif typ in ("float",):
            out[k] = float(v)
        elif typ in ("bool",):
            out[k] = v.lower() in ("1", "true", "yes")
        else:
            out[k] = v
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    sub = ap.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--tf", default="5min", help="pandas offset: 3min/5min/15min")
    common.add_argument("--data", default=DATA_FILE)
    common.add_argument("--start", default=None, help="clip data start (YYYY-MM-DD)")
    common.add_argument("--end", default=None, help="clip data end (YYYY-MM-DD)")
    common.add_argument("--param", action="append", help="override, e.g. rr_mult=2.0")

    b = sub.add_parser("backtest", parents=[common], help="single backtest, prints stats + monthly table")
    b.add_argument("--trades-out", default=None, help="write trade list CSV here")

    op = sub.add_parser("optimize", parents=[common], help="grid search with train/validation split")
    op.add_argument("--split", default="2026-04-01", help="validation start date")
    op.add_argument("--min-trades", type=int, default=60)

    sub.add_parser("optimize-all", parents=[common], help="optimize 3min, 5min and 15min")

    args = ap.parse_args()
    m1 = load_m1(args.data)
    if args.start:
        m1 = m1[m1.index >= args.start]
    if args.end:
        m1 = m1[m1.index < args.end]
    overrides = parse_overrides(args.param)

    def run_tf(tf: str):
        df = resample(m1, tf)
        print(f"\n=== {tf}  bars={len(df)}  {df.index[0]} .. {df.index[-1]} ===")
        return df

    if args.cmd == "backtest":
        df = run_tf(args.tf)
        p = replace(Params(), **overrides)
        trades, stats = run_backtest(df, p)
        print("Params:", json.dumps(asdict(p)))
        print("Stats :", json.dumps(stats))
        print("\nMonthly:")
        print(monthly_table(trades).to_string())
        if args.trades_out:
            rows = [{"time": tr.entry_time, "dir": tr.direction, "entry": tr.entry,
                     "stop": tr.stop, "target": tr.target, "exit_time": tr.exit_time,
                     "exit": tr.exit, "reason": tr.reason, "r": round(tr.r_multiple, 3)}
                    for tr in trades]
            pd.DataFrame(rows).to_csv(args.trades_out, index=False)
            print(f"\nTrades written to {args.trades_out}")

    elif args.cmd == "optimize":
        df = run_tf(args.tf)
        finalists = optimize(df, args.tf, args.split, replace(Params(), **overrides),
                             args.min_trades)
        print(json.dumps(finalists, indent=2, default=str))

    elif args.cmd == "optimize-all":
        out = {}
        for tf, mt in (("3min", 90), ("5min", 60), ("15min", 30)):
            df = run_tf(tf)
            out[tf] = optimize(df, tf, "2026-04-01", replace(Params(), **overrides), mt)
            print(json.dumps(out[tf][:3], indent=2, default=str))
        with open(os.path.join(HERE, "optimize_results.json"), "w") as fh:
            json.dump(out, fh, indent=2, default=str)
        print("\nFull results -> backtester/optimize_results.json")


if __name__ == "__main__":
    main()
