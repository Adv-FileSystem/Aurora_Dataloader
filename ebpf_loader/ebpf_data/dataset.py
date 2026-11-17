"""Dataset that turns eBPF event files into windows of aggregated features."""
import numpy as np

from .aggregate import aggregate_events
from .clean import finalize_events, normalize_events
from .filters import filter_events, filter_time_range
from .labels import interval_labels, load_intervals
from .readers import load_events
from .schema import EventSchema
from .windows import sliding_windows, window_labels


def build_series(cfg):
    """read -> normalize -> filter -> aggregate. Returns ``(table, point_labels)``."""
    schema = EventSchema.from_mapping(cfg.get("columns") or {})
    raw = load_events(cfg["source"])
    events = finalize_events(normalize_events(raw, schema, cfg.get("ts_unit", "ns")))

    f = cfg.get("filter") or {}
    events = filter_events(events, f.get("pids"), f.get("comms"), f.get("events"), f.get("exclude_events"))
    events = filter_time_range(events, f.get("start_sec"), f.get("end_sec"))
    if events.empty:
        raise ValueError("no events left after filtering")

    agg = cfg.get("aggregate") or {}
    interval = float(agg.get("interval_sec", 1.0))
    table = aggregate_events(events, interval, agg.get("events"))

    lab = cfg.get("labels") or {}
    if lab.get("intervals"):
        labels = interval_labels(len(table), load_intervals(lab["intervals"]), interval)
    else:
        labels = np.zeros(len(table), dtype=np.int64)
    return table, labels


class EBPFDataset:
    """Sliding-window dataset over aggregated eBPF features.

    ``ds[i]`` returns ``(window, label)``; ``window`` has shape (size, n_features).
    """

    def __init__(self, cfg):
        self.cfg = cfg
        self.table, self.point_labels = build_series(cfg)
        self.feature_names = list(self.table.columns)
        values = self.table.to_numpy(dtype=np.float32)
        self.values = values

        w = cfg.get("window") or {}
        size, stride = int(w.get("size", 60)), int(w.get("stride", 10))
        self.windows = sliding_windows(values, size, stride)
        self.labels = window_labels(self.point_labels, size, stride)

    def __len__(self):
        return len(self.windows)

    def __getitem__(self, idx):
        return self.windows[idx], self.labels[idx]
