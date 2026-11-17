"""Normalize raw eBPF event tables into the canonical schema."""
import pandas as pd

from .schema import EventSchema

TS_FACTORS = {"ns": 1, "us": 1_000, "ms": 1_000_000, "s": 1_000_000_000}


def normalize_events(df: pd.DataFrame, schema: EventSchema = None, ts_unit: str = "ns") -> pd.DataFrame:
    """Rename columns, cast types and drop rows without a timestamp or event name."""
    schema = schema or EventSchema()
    if ts_unit not in TS_FACTORS:
        raise ValueError(f"ts_unit must be one of {list(TS_FACTORS)}, got {ts_unit!r}")
    rename = schema.resolve(df.columns)
    keep = [c for c in df.columns if c in rename or c == "source_file"]
    out = df[keep].rename(columns=rename).copy()

    out["ts_ns"] = pd.to_numeric(out["ts_ns"], errors="coerce") * TS_FACTORS[ts_unit]
    out["event"] = out["event"].astype("string").str.strip()
    for col in ("pid", "tid", "ret"):
        if col in out:
            out[col] = pd.to_numeric(out[col], errors="coerce").astype("Int64")
    for col in ("latency_ns", "bytes"):
        if col in out:
            out[col] = pd.to_numeric(out[col], errors="coerce").astype("float64")
    for col in ("comm", "filename"):
        if col in out:
            out[col] = out[col].astype("string")

    out = out.dropna(subset=["ts_ns", "event"])
    out = out[out["event"] != ""]
    out["ts_ns"] = out["ts_ns"].round().astype("int64")
    return out.reset_index(drop=True)


def finalize_events(df: pd.DataFrame, dedupe: bool = True) -> pd.DataFrame:
    """Sort by time, drop exact duplicates and add ``t_sec`` (seconds since the first event)."""
    out = df.sort_values("ts_ns", kind="stable")
    if dedupe:
        out = out.drop_duplicates()
    out = out.reset_index(drop=True)
    t0 = out["ts_ns"].iloc[0] if len(out) else 0
    out["t_sec"] = (out["ts_ns"] - t0) / 1e9
    return out
