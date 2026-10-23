#!/usr/bin/env python3
"""Per-region cycle-count stats (min/max/mean) per cluster, straight from the
[BENCH] lines a GVSoC run emits for every mempool_start_benchmark() /
mempool_stop_benchmark() pair.

No app source is read: a region is identified only by its numeric index (the
order mempool_start_benchmark() was called in, per core), same as the `region=`
field in the log. Cross-reference that index against the mempool_start_benchmark()
call order in the app's main.c if you want to know which stage it is.

    ./bench_region_stats.py log_bench.log --csv out.csv
"""

import argparse
import csv
import re
import sys
from collections import defaultdict
from statistics import mean

BENCH_RE = re.compile(
    r"^\[BENCH\] cycles=(?P<cycles>-?\d+) ns=(?P<ns>-?\d+) "
    r"start=(?P<start>\d+) end=(?P<end>\d+) region=(?P<region>\d+) "
    r"hart=(?P<hart>\d+) path=(?P<path>\S+)"
)
# Multi-cluster mc_pool target: /system/cluster_N/...
CLUSTER_RE = re.compile(r"^/system/(cluster_\d+)/")
# Standalone (single-cluster) mempool/tensorpool target: /mempool_soc/...,
# with no cluster_N component since there's only ever one cluster.
SINGLE_CLUSTER_RE = re.compile(r"^/mempool_soc/")


def cluster_id(name):
    """-> the N of 'cluster_N'; also the sort key wherever clusters are listed."""
    return int(name.split("_")[1])


def parse(path):
    """-> {(cluster, region): [cycles, ...]}, one entry per (core, region) line."""
    data = defaultdict(list)
    nbench = 0
    for line in open(path, errors="replace"):
        m = BENCH_RE.match(line)
        if not m:
            continue
        nbench += 1
        path = m.group("path")
        c = CLUSTER_RE.match(path)
        if c:
            cluster = c.group(1)
        elif SINGLE_CLUSTER_RE.match(path):
            cluster = "cluster_0"
        else:
            print(f"warning: unrecognised path {path}", file=sys.stderr)
            continue
        data[(cluster, int(m.group("region")))].append(int(m.group("cycles")))
    return data, nbench


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", help="GVSoC run log containing [BENCH] lines")
    ap.add_argument("--csv", required=True, metavar="FILE", help="output CSV path")
    args = ap.parse_args()

    data, nbench = parse(args.log)
    if not nbench:
        print(f"error: no [BENCH] lines found in {args.log}", file=sys.stderr)
        sys.exit(1)

    rows = []
    for (cluster, region), cycles in data.items():
        rows.append({
            "cluster": cluster,
            "region": region,
            "n_cores": len(cycles),
            "min_cycles": min(cycles),
            "max_cycles": max(cycles),
            "mean_cycles": round(mean(cycles), 1),
        })
    rows.sort(key=lambda r: (cluster_id(r["cluster"]), r["region"]))

    with open(args.csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=[
            "cluster", "region", "n_cores", "min_cycles", "max_cycles", "mean_cycles"])
        w.writeheader()
        w.writerows(rows)

    print(f"parsed {nbench} [BENCH] lines -> {len(rows)} (cluster, region) rows "
          f"written to {args.csv}")


if __name__ == "__main__":
    main()
