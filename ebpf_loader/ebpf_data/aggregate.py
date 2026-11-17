"""Aggregate event tables into fixed-interval multivariate time series."""
import numpy as np
import pandas as pd

FEATURES = ("count", "bytes", "lat_mean", "lat_p95", "lat_max", "errors")


def assign_bins(df: pd.DataFrame, interval_sec: float = 1.0, column: str = "t_sec") -> np.ndarray:
    """Integer bin index of each event."""
    if interval_sec <= 0:
        raise ValueError("interval_sec must be positive")
    return np.floor(df[column].to_numpy(dtype=float) / interval_sec).astype(np.int64)


def _pivot(data, values, aggfunc, suffix):
    table = data.pivot_table(index="bin", columns="event", values=values, aggfunc=aggfunc)
    table.columns = [f"{e}_{suffix}" for e in table.columns]
    return table


def aggregate_events(df: pd.DataFrame, interval_sec: float = 1.0, events=None, n_bins=None) -> pd.DataFrame:
    """Return a DataFrame indexed by bin with ``<event>_<feature>`` columns.

    ``events`` fixes the event types and their order (missing ones become all-zero
    columns), so train and test data get identical feature layouts.
    ``n_bins`` forces the series length; by default it runs to the last event.
    """
    data = df.assign(bin=assign_bins(df, interval_sec))
    if events is not None:
        data = data[data["event"].isin(list(events))]
    parts = [_pivot(data, "ts_ns", "count", "count")]
    if "bytes" in data:
        parts.append(_pivot(data, "bytes", "sum", "bytes"))
    if "latency_ns" in data and data["latency_ns"].notna().any():
        lat = data.assign(latency_us=data["latency_ns"] / 1e3)
        parts.append(_pivot(lat, "latency_us", "mean", "lat_mean"))
        parts.append(_pivot(lat, "latency_us", lambda s: s.quantile(0.95), "lat_p95"))
        parts.append(_pivot(lat, "latency_us", "max", "lat_max"))
    if "ret" in data:
        err = data.assign(is_error=(data["ret"].fillna(0) < 0).astype(int))
        parts.append(_pivot(err, "is_error", "sum", "errors"))
    table = pd.concat(parts, axis=1).fillna(0.0)

    names = list(events) if events is not None else sorted(data["event"].unique())
    columns = [f"{e}_{f}" for e in names for f in FEATURES]
    last = int(data["bin"].max()) + 1 if len(data) else 0
    index = pd.RangeIndex(n_bins if n_bins is not None else last, name="bin")
    return table.reindex(index=index, columns=columns, fill_value=0.0).astype("float32")
