"""Bin labels from anomaly intervals."""
import numpy as np
import pandas as pd


def load_intervals(path) -> pd.DataFrame:
    """CSV with ``start_sec,end_sec`` columns, in seconds relative to the first event."""
    df = pd.read_csv(path)
    missing = {"start_sec", "end_sec"} - set(df.columns)
    if missing:
        raise ValueError(f"interval file needs start_sec and end_sec columns; missing {sorted(missing)}")
    return df


def interval_labels(n_bins: int, intervals: pd.DataFrame, interval_sec: float = 1.0) -> np.ndarray:
    """1 for every bin overlapping a ``[start_sec, end_sec)`` interval."""
    labels = np.zeros(n_bins, dtype=np.int64)
    for start, end in intervals[["start_sec", "end_sec"]].itertuples(index=False):
        lo = max(0, int(np.floor(start / interval_sec)))
        hi = min(n_bins, int(np.ceil(end / interval_sec)))
        if hi > lo:
            labels[lo:hi] = 1
    return labels
