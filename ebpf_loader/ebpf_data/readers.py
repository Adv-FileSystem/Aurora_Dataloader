"""Readers for eBPF event files (CSV, JSON Lines; optionally gzip-compressed)."""
import glob
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


SUPPORTED = (".csv", ".jsonl", ".ndjson", ".json", ".csv.gz", ".jsonl.gz", ".ndjson.gz", ".json.gz")


def find_event_files(source):
    """Resolve a file, a directory (searched recursively) or a glob pattern."""
    p = Path(source)
    if p.is_file():
        return [p]
    if p.is_dir():
        files = [f for f in p.rglob("*") if f.is_file() and f.name.lower().endswith(SUPPORTED)]
    else:
        files = [Path(f) for f in glob.glob(str(source), recursive=True)]
    files = sorted(files)
    if not files:
        raise FileNotFoundError(f"no event files found in {source}")
    return files


def load_events(source, add_source_column: bool = True) -> pd.DataFrame:
    """Read every event file under ``source`` into one DataFrame."""
    frames = []
    for f in find_event_files(source):
        df = read_events(f)
        if add_source_column:
            df["source_file"] = f.name
        frames.append(df)
    return pd.concat(frames, ignore_index=True)
