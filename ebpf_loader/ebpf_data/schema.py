"""Column schema for eBPF event records."""
from dataclasses import dataclass, field
from typing import Dict, List, Optional

CANONICAL = ("ts_ns", "pid", "tid", "comm", "event", "latency_ns", "bytes", "ret", "filename")
REQUIRED = ("ts_ns", "event")

DEFAULT_ALIASES = {
    "ts_ns": ["ts_ns", "timestamp_ns", "timestamp", "ts", "time_ns"],
    "pid": ["pid", "tgid"],
    "tid": ["tid"],
    "comm": ["comm", "process", "task"],
    "event": ["event", "syscall", "probe", "op", "type"],
    "latency_ns": ["latency_ns", "lat_ns", "latency", "duration_ns", "delta_ns"],
    "bytes": ["bytes", "size", "len"],
    "ret": ["ret", "retval", "return"],
    "filename": ["filename", "file", "path", "fname"],
}


@dataclass
class EventSchema:
    """Maps raw column names to canonical names.

    ``explicit`` (``{canonical: raw_column}``) wins over the alias lists.
    """

    explicit: Dict[str, str] = field(default_factory=dict)
    aliases: Dict[str, List[str]] = field(
        default_factory=lambda: {k: list(v) for k, v in DEFAULT_ALIASES.items()}
    )

    @classmethod
    def from_mapping(cls, mapping: Optional[Dict[str, str]] = None) -> "EventSchema":
        for canon in mapping or {}:
            if canon not in CANONICAL:
                raise KeyError(f"unknown canonical column {canon!r}; expected one of {CANONICAL}")
        return cls(explicit=dict(mapping or {}))

    def resolve(self, columns) -> Dict[str, str]:
        """Return ``{raw_column: canonical}`` for the columns present."""
        cols = list(columns)
        lower = {str(c).lower(): c for c in cols}
        rename = {}
        for canon, raw in self.explicit.items():
            if raw not in cols:
                raise ValueError(f"mapped column {raw!r} for {canon!r} not found in {cols}")
            rename[raw] = canon
        for canon in CANONICAL:
            if canon in rename.values():
                continue
            for alias in self.aliases.get(canon, []):
                raw = lower.get(alias.lower())
                if raw is not None and raw not in rename:
                    rename[raw] = canon
                    break
        missing = [c for c in REQUIRED if c not in rename.values()]
        if missing:
            raise ValueError(f"required columns not found: {missing}; got {cols}")
        return rename
