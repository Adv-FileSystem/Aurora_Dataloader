"""Aggregate event tables into fixed-interval multivariate time series."""
import numpy as np
import pandas as pd


def assign_bins(df: pd.DataFrame, interval_sec: float = 1.0, column: str = "t_sec") -> np.ndarray:
    """Integer bin index of each event."""
    if interval_sec <= 0:
        raise ValueError("interval_sec must be positive")
    return np.floor(df[column].to_numpy(dtype=float) / interval_sec).astype(np.int64)


def aggregate_events(df: pd.DataFrame, interval_sec: float = 1.0, events=None) -> pd.DataFrame:
    """Return a DataFrame indexed by bin with ``<event>_<feature>`` columns.

    ``events`` restricts and orders the event types.
    """
    data = df.assign(bin=assign_bins(df, interval_sec))
    if events is not None:
        data = data[data["event"].isin(list(events))]
    counts = data.pivot_table(index="bin", columns="event", values="ts_ns", aggfunc="count", fill_value=0)
    counts.columns = [f"{e}_count" for e in counts.columns]
    return counts.sort_index()
    return table.sort_index()  #@aggmore
