"""Load eBPF event files and turn them into windowed time-series features.

Example:
    python scripts/load_ebpf.py --source ./data/ebpf --interval 1.0 --window 60
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ebpf_data.dataset import EBPFDataset  # noqa: E402


def parse_args():
    p = argparse.ArgumentParser(description="Load eBPF events into windowed time-series features.")
    p.add_argument("--config", default=str(ROOT / "configs" / "default.yaml"))
    p.add_argument("--source", help="override source (file, directory or glob)")
    p.add_argument("--ts-unit", choices=["ns", "us", "ms", "s"], help="override ts_unit")
    p.add_argument("--interval", type=float, help="override aggregate.interval_sec")
    p.add_argument("--window", type=int, help="override window.size")
    p.add_argument("--stride", type=int, help="override window.stride")
    p.add_argument("--labels", help="override labels.intervals")
    p.add_argument("--out", help="override output.dir")
    return p.parse_args()


def load_config(path, args):
    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    if args.source:
        cfg["source"] = args.source
    if args.ts_unit:
        cfg["ts_unit"] = args.ts_unit
    if args.interval is not None:
        cfg.setdefault("aggregate", {})["interval_sec"] = args.interval
    if args.window is not None:
        cfg.setdefault("window", {})["size"] = args.window
    if args.stride is not None:
        cfg.setdefault("window", {})["stride"] = args.stride
    if args.labels:
        cfg.setdefault("labels", {})["intervals"] = args.labels
    if args.out:
        cfg.setdefault("output", {})["dir"] = args.out
    return cfg


def save_outputs(ds, out_dir, cfg):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        out / "ebpf_windows.npz",
        windows=ds.windows,
        labels=ds.labels,
        feature_names=np.array(ds.feature_names),
    )
    ds.table.to_csv(out / "ebpf_series.csv")
    with open(out / "config.yaml", "w", encoding="utf-8") as f:
        yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
    return out


def main():
    args = parse_args()
    cfg = load_config(args.config, args)
    ds = EBPFDataset(cfg)
    print(f"bins: {len(ds.table)}  features: {len(ds.feature_names)}")
    print(f"windows: {ds.windows.shape}  anomalous windows: {int(ds.labels.sum())}")
    out = save_outputs(ds, (cfg.get("output") or {}).get("dir", "./outputs/ebpf"), cfg)
    print(f"saved -> {out}")


if __name__ == "__main__":
    main()
