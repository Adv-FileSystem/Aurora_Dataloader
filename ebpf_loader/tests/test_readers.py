import json

import pandas as pd
import pytest

from ebpf_data.clean import finalize_events, normalize_events
from ebpf_data.readers import load_events, read_events
from ebpf_data.schema import EventSchema

ROWS = [
    {"timestamp": 3_000_000_000, "pid": 1, "comm": "fio", "syscall": "write", "lat_ns": 2000, "size": 4096, "ret": 4096},
    {"timestamp": 1_000_000_000, "pid": 1, "comm": "fio", "syscall": "read", "lat_ns": 1000, "size": 512, "ret": 512},
    {"timestamp": 1_000_000_000, "pid": 1, "comm": "fio", "syscall": "read", "lat_ns": 1000, "size": 512, "ret": 512},
    {"timestamp": 2_000_000_000, "pid": 2, "comm": "pg", "syscall": "fsync", "lat_ns": 9000, "size": 0, "ret": -5},
]


def test_csv_and_jsonl_give_same_events(tmp_path):
    pd.DataFrame(ROWS).to_csv(tmp_path / "a.csv", index=False)
    with open(tmp_path / "b.jsonl", "w", encoding="utf-8") as f:
        for row in ROWS:
            f.write(json.dumps(row) + "\n")
    a = normalize_events(read_events(tmp_path / "a.csv"))
    b = normalize_events(read_events(tmp_path / "b.jsonl"))
    assert list(a.columns) == list(b.columns)
    assert a["event"].tolist() == b["event"].tolist()
    assert a["ts_ns"].tolist() == b["ts_ns"].tolist()


def test_aliases_are_resolved():
    df = normalize_events(pd.DataFrame(ROWS))
    assert {"ts_ns", "pid", "comm", "event", "latency_ns", "bytes", "ret"} <= set(df.columns)


def test_explicit_mapping_wins():
    raw = pd.DataFrame({"time": [1, 2], "probe_name": ["vfs_read", "vfs_write"]})
    df = normalize_events(raw, EventSchema.from_mapping({"ts_ns": "time", "event": "probe_name"}))
    assert df["event"].tolist() == ["vfs_read", "vfs_write"]


def test_missing_required_column_raises():
    with pytest.raises(ValueError):
        normalize_events(pd.DataFrame({"pid": [1]}))


def test_ts_unit_conversion():
    df = normalize_events(pd.DataFrame({"ts": [1.5], "event": ["read"]}), ts_unit="s")
    assert df["ts_ns"].iloc[0] == 1_500_000_000


def test_finalize_sorts_and_dedupes():
    df = finalize_events(normalize_events(pd.DataFrame(ROWS)))
    assert len(df) == 3
    assert df["ts_ns"].is_monotonic_increasing
    assert df["t_sec"].tolist() == [0.0, 1.0, 2.0]


def test_load_events_from_directory(tmp_path):
    pd.DataFrame(ROWS[:2]).to_csv(tmp_path / "x.csv", index=False)
    pd.DataFrame(ROWS[2:]).to_csv(tmp_path / "y.csv.gz", index=False)
    df = load_events(tmp_path)
    assert len(df) == 4
    assert set(df["source_file"]) == {"x.csv", "y.csv.gz"}
