"""Filters for normalized event tables."""
import pandas as pd


def _as_list(value):
    if value is None:
        return None
    return list(value) if isinstance(value, (list, tuple, set)) else [value]


def filter_events(df: pd.DataFrame, pids=None, comms=None, events=None, exclude_events=None) -> pd.DataFrame:
    """Keep rows matching the given pids / process names / event types."""
    mask = pd.Series(True, index=df.index)
    if pids is not None and "pid" in df:
        mask &= df["pid"].isin(_as_list(pids)).fillna(False).astype(bool)
    if comms is not None and "comm" in df:
        mask &= df["comm"].isin(_as_list(comms)).fillna(False).astype(bool)
    if events is not None:
        mask &= df["event"].isin(_as_list(events)).fillna(False).astype(bool)
    if exclude_events is not None:
        mask &= ~df["event"].isin(_as_list(exclude_events)).fillna(False).astype(bool)
    return df[mask].reset_index(drop=True)
