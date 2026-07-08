#!/usr/bin/env python3
"""
Fetch ~13 months of XAUUSD 1-minute candles and write a normalized CSV.

Designed to run on a GitHub Actions runner (open internet). Two sources,
tried in order:

  1. Dukascopy datafeed — one BID_candles_min_1.bi5 file per calendar day
     (LZMA-compressed big-endian records). Timestamps UTC.
  2. HistData.com monthly M1 zips (via the `histdata` pip package).
     Timestamps are EST *without* DST (UTC-5 fixed) and are converted to UTC.

Output CSV columns: timestamp(ms epoch UTC), open, high, low, close, volume
— the same shape dukascopy-node produces, which backtester/smc_backtest.py
already understands.

Usage:
  python3 backtester/fetch_data.py --from 2025-06-01 --to 2026-07-05 \
      --out dl-tmp/XAUUSD_M1.csv
"""

from __future__ import annotations

import argparse
import datetime as dt
import io
import lzma
import os
import struct
import sys
import time
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")

DUKA_URL = ("https://datafeed.dukascopy.com/datafeed/XAUUSD/"
            "{y}/{m0:02d}/{d:02d}/BID_candles_min_1.bi5")

REC = struct.Struct(">IIIIIf")  # secs offset, then 4 int prices, float volume


def http_get(url: str, retries: int = 3, timeout: int = 12) -> bytes | None:
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None  # no data for this day (weekend/holiday)
            last = e
        except Exception as e:  # noqa: BLE001 - network errors of all kinds
            last = e
        time.sleep(1.0 * (attempt + 1))
    print(f"  giving up on {url}: {last}", file=sys.stderr)
    return None


def detect_scale(raw_prices: list[int]) -> float:
    for scale in (1000.0, 100000.0, 100.0, 10.0):
        med = sorted(p / scale for p in raw_prices)[len(raw_prices) // 2]
        if 300 <= med <= 10000:  # plausible gold price band
            return scale
    raise ValueError(f"cannot detect price scale, sample={raw_prices[:5]}")


def parse_bi5(blob: bytes, day: dt.date, scale_holder: dict) -> list[tuple]:
    if not blob:
        return []
    try:
        data = lzma.decompress(blob)
    except lzma.LZMAError:
        data = lzma.decompress(blob, format=lzma.FORMAT_ALONE)
    n = len(data) // REC.size
    rows = []
    base_ms = int(dt.datetime(day.year, day.month, day.day,
                              tzinfo=dt.timezone.utc).timestamp() * 1000)
    recs = [REC.unpack_from(data, i * REC.size) for i in range(n)]
    if not recs:
        return []
    if "scale" not in scale_holder:
        scale_holder["scale"] = detect_scale([r[1] for r in recs[:200]])
        # Dukascopy candle field order is (open, close, low, high); verify
        # against the alternative OHLC order and keep whichever is coherent
        # (low must not exceed open/close and high must not be below them).
        oclh_ok = ohlc_ok = 0
        for r in recs[:200]:
            a, b, c2, d2 = r[1], r[2], r[3], r[4]
            if c2 <= min(a, b) and d2 >= max(a, b):   # o=a c=b l=c2 h=d2
                oclh_ok += 1
            if c2 <= min(a, d2) and b >= max(a, d2):  # o=a h=b l=c2 c=d2
                ohlc_ok += 1
        scale_holder["order"] = "oclh" if oclh_ok >= ohlc_ok else "ohlc"
        print(f"  detected scale={scale_holder['scale']} order={scale_holder['order']}")
    scale = scale_holder["scale"]
    for r in recs:
        secs, a, b, c_, d, vol = r
        if scale_holder["order"] == "oclh":
            o_, cl, lo, hi = a / scale, b / scale, c_ / scale, d / scale
        else:
            o_, hi, lo, cl = a / scale, b / scale, c_ / scale, d / scale
        if hi < lo:
            lo, hi = hi, lo
        if hi <= 0:
            continue
        rows.append((base_ms + secs * 1000, o_, hi, lo, cl, round(float(vol), 4)))
    return rows


def fetch_dukascopy(d_from: dt.date, d_to: dt.date,
                    workers: int = 8, budget_secs: int = 18 * 60) -> list[tuple]:
    from concurrent.futures import ThreadPoolExecutor, as_completed

    days = [d_from + dt.timedelta(days=i) for i in range((d_to - d_from).days + 1)]
    rows: list[tuple] = []
    holder: dict = {}
    got_days = miss_days = 0
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futs = {pool.submit(
            http_get, DUKA_URL.format(y=d.year, m0=d.month - 1, d=d.day)): d
            for d in days}
        for fut in as_completed(futs):
            day = futs[fut]
            blob = fut.result()
            if blob:
                rows.extend(parse_bi5(blob, day, holder))
                got_days += 1
            else:
                miss_days += 1
            done = got_days + miss_days
            if done % 50 == 0:
                print(f"  {done}/{len(days)} days, ok={got_days} rows={len(rows)}"
                      f" elapsed={time.monotonic()-started:.0f}s", flush=True)
            # dead source detection: nothing but misses early on
            if (done >= 60 and got_days == 0) or time.monotonic() - started > budget_secs:
                print("  Dukascopy unreachable/budget exceeded — stopping", flush=True)
                for f in futs:
                    f.cancel()
                break
    print(f"Dukascopy: {got_days} days with data, {miss_days} empty, {len(rows)} rows")
    return rows


def fetch_histdata(d_from: dt.date, d_to: dt.date) -> list[tuple]:
    from histdata import download_hist_data
    from histdata.api import Platform, TimeFrame
    import zipfile

    rows: list[tuple] = []
    est_to_utc = dt.timedelta(hours=5)  # HistData uses fixed UTC-5, no DST
    cur_year = dt.date.today().year
    # HistData packaging: past years -> ONE yearly zip (month must be None);
    # current year -> one zip per month.
    jobs: list[tuple[str, str | None]] = []
    for y in range(d_from.year, min(d_to.year, cur_year - 1) + 1):
        if y < cur_year:
            jobs.append((str(y), None))
    if d_to.year == cur_year:
        last_m = d_to.month if d_to.year == cur_year else 12
        for m in range(1, last_m + 1):
            jobs.append((str(cur_year), str(m)))
    for year, month in jobs:
        try:
            path = download_hist_data(year=year, month=month,
                                      pair="xauusd",
                                      platform=Platform.GENERIC_ASCII,
                                      time_frame=TimeFrame.ONE_MINUTE,
                                      output_directory="hist-tmp", verbose=False)
        except Exception as e:  # month not published yet, etc.
            print(f"  histdata {year}-{month}: {e}", file=sys.stderr)
            path = None
        if path and os.path.exists(path):
            with zipfile.ZipFile(path) as zf:
                name = [n for n in zf.namelist() if n.endswith(".csv")][0]
                for line in io.TextIOWrapper(zf.open(name), encoding="utf-8"):
                    try:
                        stamp, o_, hi, lo, cl, vol = line.strip().split(";")
                        t = dt.datetime.strptime(stamp, "%Y%m%d %H%M%S") + est_to_utc
                        t = t.replace(tzinfo=dt.timezone.utc)
                        if d_from <= t.date() <= d_to:
                            rows.append((int(t.timestamp() * 1000), float(o_),
                                         float(hi), float(lo), float(cl), float(vol)))
                    except ValueError:
                        continue
    print(f"HistData: {len(rows)} rows")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="date_from", default="2025-06-01")
    ap.add_argument("--to", dest="date_to", default="2026-07-05")
    ap.add_argument("--out", default="dl-tmp/XAUUSD_M1.csv")
    args = ap.parse_args()
    d_from = dt.date.fromisoformat(args.date_from)
    d_to = dt.date.fromisoformat(args.date_to)

    rows = fetch_dukascopy(d_from, d_to)
    expected_days = sum(1 for i in range((d_to - d_from).days + 1)
                        if (d_from + dt.timedelta(days=i)).weekday() < 5)
    min_rows = expected_days * 800  # gold trades ~1380 M1 bars per weekday
    if len(rows) < min_rows:
        print(f"Dukascopy insufficient ({len(rows)} < {min_rows}), trying HistData...")
        os.system(f"{sys.executable} -m pip install --quiet histdata")
        hd = fetch_histdata(d_from, d_to)
        if len(hd) > len(rows):
            rows = hd
    if len(rows) < min_rows:
        sys.exit(f"FATAL: only {len(rows)} rows fetched (needed >= {min_rows})")

    rows.sort(key=lambda r: r[0])
    dedup = []
    last_t = None
    for r in rows:
        if r[0] != last_t:
            dedup.append(r)
            last_t = r[0]

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as fh:
        fh.write("timestamp,open,high,low,close,volume\n")
        for r in dedup:
            fh.write(f"{r[0]},{r[1]},{r[2]},{r[3]},{r[4]},{r[5]}\n")
    first = dt.datetime.fromtimestamp(dedup[0][0] / 1000, dt.timezone.utc)
    last = dt.datetime.fromtimestamp(dedup[-1][0] / 1000, dt.timezone.utc)
    print(f"Wrote {len(dedup)} rows to {args.out}  ({first} .. {last})")
    # sanity: print a few rows
    for r in dedup[:2] + dedup[-2:]:
        print("  sample:", r)


if __name__ == "__main__":
    main()
