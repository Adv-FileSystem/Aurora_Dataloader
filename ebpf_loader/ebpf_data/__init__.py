"""Data loader for eBPF event traces."""

from .aggregate import FEATURES, aggregate_events
from .clean import finalize_events, normalize_events
from .dataset import EBPFDataset, build_series
from .readers import load_events, read_events
from .schema import EventSchema

__version__ = "0.1.0"
