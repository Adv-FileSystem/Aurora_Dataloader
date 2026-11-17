# eBPF Data Loader

Loads eBPF event traces (syscalls, VFS / block I/O probes, ...) and turns them into
fixed-interval multivariate time series and sliding windows for anomaly detection.


## Input format

One event per row, as CSV or JSON Lines (optionally `.gz`).
Column names are matched case-insensitively through aliases; you can also map them
explicitly with `columns:` in the config.

| canonical | required | accepted aliases |
|---|---|---|
| `ts_ns` | yes | `timestamp_ns`, `timestamp`, `ts`, `time_ns` (unit set by `ts_unit`) |
| `event` | yes | `syscall`, `probe`, `op`, `type` |
| `pid` / `tid` | no | `tgid` |
| `comm` | no | `process`, `task` |
| `latency_ns` | no | `lat_ns`, `latency`, `duration_ns`, `delta_ns` |
| `bytes` | no | `size`, `len` |
| `ret` | no | `retval`, `return` (negative = error) |
| `filename` | no | `file`, `path`, `fname` |

Example (CSV):

```
ts_ns,pid,comm,event,latency_ns,bytes,ret
1700000000001234567,1201,postgres,write,35210,4096,4096
1700000000002345678,1201,postgres,fsync,912000,0,0
```

## Features

Events are binned every `aggregate.interval_sec` seconds. For each event type:
`count`, `bytes` (sum), `lat_mean` / `lat_p95` / `lat_max` (microseconds), `errors` (ret < 0).
Empty bins are filled with 0, and the feature order is fixed by `aggregate.events`.

## Usage

```bash
pip install -r requirements.txt

# try it with synthetic data
python scripts/make_sample_events.py --out ./data/ebpf/sample.csv
python scripts/load_ebpf.py --source ./data/ebpf --labels ./data/ebpf_anomalies.csv
```

In Python:

```python
from ebpf_data import EBPFDataset

ds = EBPFDataset({"source": "./data/ebpf", "window": {"size": 60, "stride": 10}})
x, y = ds[0]            # (60, n_features), label
torch_ds = ds.as_torch()  # requires torch
```

Outputs of the CLI (`output.dir`): `ebpf_windows.npz` (windows, labels, feature_names),
`ebpf_series.csv` (aggregated series) and `config.yaml`.

## Tests

```bash
pytest -q
```
