"""Generate a synthetic eBPF-style event trace to try out the loader.

Example:
    python scripts/make_sample_events.py --out ./data/ebpf/sample.csv --seconds 600
"""
import argparse
from pathlib import Path

import numpy as np
import pandas as pd

# event -> (max bytes, mean latency in microseconds)
EVENTS = {"read": (4096, 20.0), "write": (4096, 35.0), "openat": (0, 8.0), "fsync": (0, 900.0)}
RATES = {"read": 50, "write": 30, "openat": 5, "fsync": 1}  # events per second


def make_events(seconds: int, seed: int = 0, anomaly=None) -> pd.DataFrame:
    """Poisson event streams; inside ``anomaly=(start, end)`` fsync bursts and latency rises."""
    rng = np.random.default_rng(seed)
    t0 = 1_700_000_000_000_000_000
    frames = []
    for sec in range(seconds):
        burst = anomaly is not None and anomaly[0] <= sec < anomaly[1]
        for ev, rate in RATES.items():
            n = int(rng.poisson(rate * (5 if burst and ev == "fsync" else 1)))
            if n == 0:
                continue
            size, lat_us = EVENTS[ev]
            frames.append(pd.DataFrame({
                "ts_ns": (t0 + (sec + np.sort(rng.random(n))) * 1e9).astype(np.int64),
                "pid": rng.choice([1201, 1202, 2310], n),
                "comm": rng.choice(["postgres", "fio"], n),
                "event": ev,
                "latency_ns": (rng.exponential(lat_us * (4 if burst else 1), n) * 1e3).astype(np.int64),
                "bytes": rng.integers(0, size + 1, n) if size else np.zeros(n, dtype=np.int64),
                "ret": np.where(rng.random(n) < 0.002, -5, 0),
            }))
    return pd.concat(frames, ignore_index=True).sort_values("ts_ns").reset_index(drop=True)


def main():
    p = argparse.ArgumentParser(description="Generate a synthetic eBPF event trace.")
    p.add_argument("--out", default="./data/ebpf/sample.csv")
    p.add_argument("--labels-out", default="./data/ebpf_anomalies.csv")
    p.add_argument("--seconds", type=int, default=600)
    p.add_argument("--seed", type=int, default=0)
    args = p.parse_args()

    anomaly = (args.seconds // 2, args.seconds // 2 + 30)
    df = make_events(args.seconds, args.seed, anomaly)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(out, index=False)

    labels = Path(args.labels_out)
    labels.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame({"start_sec": [anomaly[0]], "end_sec": [anomaly[1]]}).to_csv(labels, index=False)
    print(f"wrote {len(df)} events -> {out}")
    print(f"wrote anomaly interval {anomaly} -> {labels}")


if __name__ == "__main__":
    main()
