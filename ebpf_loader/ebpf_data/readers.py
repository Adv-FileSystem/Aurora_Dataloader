"""Readers for eBPF event files (CSV, JSON Lines; optionally gzip-compressed)."""
from pathlib import Path

import pandas as pd


def read_csv_events(path, **kwargs) -> pd.DataFrame:
    """Read a CSV file of event records."""
    return pd.read_csv(path, **kwargs)
