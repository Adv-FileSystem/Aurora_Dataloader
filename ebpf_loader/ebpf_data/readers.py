"""Readers for eBPF event files (CSV, JSON Lines; optionally gzip-compressed)."""
from pathlib import Path

import pandas as pd


def read_csv_events(path, **kwargs) -> pd.DataFrame:
    """Read a CSV file of event records."""
    return pd.read_csv(path, **kwargs)


def read_jsonl_events(path) -> pd.DataFrame:
    """Read a JSON Lines file (one event object per line)."""
    return pd.read_json(path, lines=True, convert_dates=False, keep_default_dates=False)


def read_events(path) -> pd.DataFrame:
    """Read one event file, choosing the reader from its extension."""
    name = Path(path).name.lower()
    if name.endswith(".gz"):
        name = name[:-3]
    if name.endswith(".csv"):
        return read_csv_events(path)
    if name.endswith((".jsonl", ".ndjson", ".json")):
        return read_jsonl_events(path)
    raise ValueError(f"unsupported event file: {path}")
