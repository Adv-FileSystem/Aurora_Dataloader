# pt_daos_io.py
import os
import json
import numpy as np
import torch
import h5py
from mpi4py import MPI

def is_daos_path(path: str) -> bool:
    return path.startswith("daos://") or path.startswith("/mnt/daos/")

def mnt_to_daos(path: str) -> str:
    if path.startswith("/mnt/daos/"):
        relative = path[len("/mnt/daos/"):]
        pool = os.environ.get("DAOS_POOL")
        cont = os.environ.get("DAOS_CONT")
        return f"daos://{pool}/{cont}/{relative}"
    return path

def to_mnt_path(path: str) -> str:
    if path.startswith("daos://"):
        return "/mnt/daos/" + path.split("/")[-1]
    return path

def get_daos_relative_path(path: str) -> str:
    if path.startswith("daos://"):
        parts = path[len("daos://"):].split("/", 2)
        return parts[2] if len(parts) == 3 else ""
    elif path.startswith("/mnt/daos/"):
        return path[len("/mnt/daos/"):]
    else:
        raise ValueError(f"Not a DAOS path: {path}")

def _from_posix(path: str, dtype=torch.float32) -> torch.Tensor:
    path = to_mnt_path(path)
    from sitecustomize import original_open

    meta_path = path + ".meta"
    if os.path.exists(meta_path):
        with original_open(meta_path, 'r') as metaf:
            meta = json.load(metaf)
            shape = tuple(meta.get("shape", ()))
            np_dtype = np.dtype(meta.get("dtype", "float32"))
    else:
            shape = None
            np_dtype = np.float32

    with original_open(path, 'rb') as f:
        buf = f.read()

    if len(buf) % np.dtype(np_dtype).itemsize != 0:
        raise ValueError(f"Buffer size {len(buf)} is not multiple of element size {np.dtype(np_dtype).itemsize}")

    arr = np.frombuffer(buf, dtype=np_dtype)

    if shape:
        arr = arr.reshape(shape)
    return torch.tensor(arr, dtype=dtype)


def _from_hdf5(path: str, dtype=torch.float32) -> torch.Tensor:
    with h5py.File(path, 'r') as f:
        data = f["data"][()]
    return torch.from_numpy(data).to(dtype)

def _from_mpiio(path: str, dtype=torch.float32) -> torch.Tensor:
    meta_path = path + ".meta"
    shape, np_dtype = (128, 128), np.float32

    if os.path.exists(meta_path):
        with open(meta_path, 'r') as metaf:
            meta = json.load(metaf)
            shape = tuple(meta.get("shape", shape))
            np_dtype = np.dtype(str(meta.get("dtype", "float32")))
    else:
        fh = MPI.File.Open(MPI.COMM_SELF, path, MPI.MODE_RDONLY)
        fh.Seek(0, MPI.SEEK_END)
        total_bytes = fh.Get_position()
        fh.Seek(0)
        count = total_bytes // np.dtype(np_dtype).itemsize
        shape = (count,)
        fh.Close()

    buf = np.empty(np.prod(shape), dtype=np_dtype)
    fh = MPI.File.Open(MPI.COMM_SELF, path, MPI.MODE_RDONLY)
    fh.Read(buf)
    fh.Close()
    return torch.from_numpy(buf.reshape(shape)).to(dtype)

