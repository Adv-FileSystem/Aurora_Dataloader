import numpy as np
import pandas as pd

from ebpf_data.aggregate import FEATURES, aggregate_events
from ebpf_data.clean import finalize_events, normalize_events
from ebpf_data.dataset import EBPFDataset
from ebpf_data.labels import interval_labels


def _events(seconds=120, gap=(40, 45)):
    rows = []
    for s in range(seconds):
        if gap[0] <= s < gap[1]:
            continue
        for k in range(3):
            rows.append({"ts_ns": int((s + k / 3) * 1e9), "event": "read",
                         "latency_ns": 1000 * (k + 1), "bytes": 100, "ret": 100})
        rows.append({"ts_ns": int((s + 0.5) * 1e9), "event": "fsync",
                     "latency_ns": 5000, "bytes": 0, "ret": -1 if s == 10 else 0})
    return pd.DataFrame(rows)


def test_aggregate_shape_and_values():
    ev = finalize_events(normalize_events(_events()))
    table = aggregate_events(ev, 1.0)
    assert len(table) == 120  # bins 40..44 have no events but are kept
    assert list(table.columns) == [f"{e}_{f}" for e in ["fsync", "read"] for f in FEATURES]
    assert table.loc[0, "read_count"] == 3
    assert table.loc[0, "read_bytes"] == 300
    assert table.loc[42, "read_count"] == 0
    assert table.loc[10, "fsync_errors"] == 1
    assert table.loc[0, "read_lat_max"] == 3.0  # microseconds


def test_fixed_event_order():
    ev = finalize_events(normalize_events(_events()))
    table = aggregate_events(ev, 1.0, events=["read", "write"])
    assert table.columns[0] == "read_count"
    assert (table["write_count"] == 0).all()


def test_interval_labels():
    labels = interval_labels(10, pd.DataFrame({"start_sec": [2.5], "end_sec": [4.0]}), 1.0)
    assert labels.tolist() == [0, 0, 1, 1, 0, 0, 0, 0, 0, 0]


def test_dataset_end_to_end(tmp_path):
    _events().to_csv(tmp_path / "ev.csv", index=False)
    pd.DataFrame({"start_sec": [60], "end_sec": [70]}).to_csv(tmp_path / "anom.csv", index=False)
    cfg = {
        "source": str(tmp_path / "ev.csv"),
        "aggregate": {"interval_sec": 1.0},
        "labels": {"intervals": str(tmp_path / "anom.csv")},
        "window": {"size": 20, "stride": 10},
    }
    ds = EBPFDataset(cfg)
    assert ds.windows.shape == (11, 20, 12)
    assert ds.labels.sum() > 0
    x, y = ds[0]
    assert x.shape == (20, 12)
    assert np.isfinite(ds.windows).all()
