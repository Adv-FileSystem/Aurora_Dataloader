# pt_daos_io.py
import os
import json
import numpy as np
import torch
import h5py
from mpi4py import MPI

DAOS_MNT_ROOT = "/mnt/daos/u"
POSIX_MNT_PREFIX = "/mnt/daos/u/posix"      # <- 행님이 원하는 POSIX 쪽 UNS 루트로 통일 추천
HDF5_MNT_PREFIX  = "/mnt/daos/u/hdf5"       # <- 요구사항 반영

def _must_env(k: str) -> str:
    v = os.environ.get(k)
    if not v:
        raise RuntimeError(f"Missing env: {k}")
    return v

def is_mnt_path(path: str) -> bool:
    return isinstance(path, str) and path.startswith("/mnt/daos/")

def is_daos_uri(path: str) -> bool:
    return isinstance(path, str) and (path.startswith("daos://") or path.startswith("daos:"))

def mnt_to_daos_posix_uri(mnt_path: str) -> str:
    # /mnt/daos/u/posix/xxx  -> daos://POOL/POSIX_CONT/xxx
    assert mnt_path.startswith(POSIX_MNT_PREFIX + "/")
    rel = mnt_path[len(POSIX_MNT_PREFIX) + 1:]
    pool = _must_env("DAOS_POOL")
    cont = _must_env("DAOS_POSIX_CONT")
    return f"daos://{pool}/{cont}/{rel}"

def mnt_to_daos_hdf5_uri(mnt_path: str) -> str:
    # /mnt/daos/u/hdf5/xxx -> daos://POOL/HDF5_CONT/xxx
    assert mnt_path.startswith(HDF5_MNT_PREFIX + "/")
    rel = mnt_path[len(HDF5_MNT_PREFIX) + 1:]
    pool = _must_env("DAOS_POOL")
    cont = _must_env("DAOS_HDF5_CONT")
    return f"daos://{pool}/{cont}/{rel}"

def mnt_to_romio_daos_path(mnt_path: str) -> str:
    """
    ROMIO 쪽은 daos:// (URI) 가 아니라 문서 예시대로 daos: prefix를 쓰는 케이스가 많음.
    핵심은 ROMIO에서 DAOS FS 드라이버를 타게 만드는 것.
    """
    # UNS를 /mnt/daos/u/posix/... 로 설계했다면 이 경로를 daos: 로 넘김
    # 예: daos:/mnt/daos/u/posix/E_x.mpi
    if not mnt_path.startswith(POSIX_MNT_PREFIX + "/"):
        raise ValueError(f"ROMIO direct expects under {POSIX_MNT_PREFIX}: {mnt_path}")
    os.environ.setdefault("ROMIO_FSTYPE_FORCE", "daos:")  # <- 강제 :contentReference[oaicite:4]{index=4}
    return "daos:" + mnt_path

def _read_meta(meta_path: str):
    if not os.path.exists(meta_path):
        return None
    with open(meta_path, "r") as f:
        meta = json.load(f)
    shape = tuple(meta.get("shape", ()))
    np_dtype = np.dtype(str(meta.get("dtype", "float32")))
    return shape, np_dtype

def _from_posix(mnt_path: str, dtype=torch.float32) -> torch.Tensor:
    # 이건 의도적으로 dfuse(POSIX) 경로.
    meta = _read_meta(mnt_path + ".meta")
    shape, np_dtype = (None, np.float32) if meta is None else meta
    with open(mnt_path, "rb") as f:
        buf = f.read()
    arr = np.frombuffer(buf, dtype=np_dtype)
    if shape:
        arr = arr.reshape(shape)
    return torch.from_numpy(arr).to(dtype)

def _from_hdf5(mnt_or_daos: str, dtype=torch.float32) -> torch.Tensor:
    # h5py + DAOS VOL: daos:// 로 direct 가능 (VOL env 필요) :contentReference[oaicite:5]{index=5}
    path = mnt_or_daos
    if path.startswith(HDF5_MNT_PREFIX + "/"):
        path = mnt_to_daos_hdf5_uri(path)
    with h5py.File(path, "r") as f:
        data = f["data"][()]
    return torch.from_numpy(data).to(dtype)

def _from_mpiio(mnt_or_daos: str, dtype=torch.float32) -> torch.Tensor:
    # ROMIO direct: daos: prefix + ROMIO_FSTYPE_FORCE 로 DAOS 강제 :contentReference[oaicite:6]{index=6}
    path = mnt_or_daos
    if path.startswith(POSIX_MNT_PREFIX + "/"):
        path = mnt_to_romio_daos_path(path)   # <- 여기서 direct 강제

    meta = _read_meta(mnt_or_daos + ".meta") if not is_daos_uri(mnt_or_daos) else None
    shape, np_dtype = ((128, 128), np.float32) if meta is None else meta

    # size 추론(메타 없을 때)
    if meta is None:
        fh = MPI.File.Open(MPI.COMM_SELF, path, MPI.MODE_RDONLY)
        total_bytes = fh.Get_size()
        fh.Close()
        count = total_bytes // np.dtype(np_dtype).itemsize
        shape = (count,)

    buf = np.empty(int(np.prod(shape)), dtype=np_dtype)
    fh = MPI.File.Open(MPI.COMM_SELF, path, MPI.MODE_RDONLY)
    fh.Read(buf)
    fh.Close()
    return torch.from_numpy(buf.reshape(shape)).to(dtype)

