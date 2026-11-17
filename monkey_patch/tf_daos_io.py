# tf_daos_io.py
import tensorflow as tf
import numpy as np
import os
import json

def _from_hdf5_as_bytes(path: str) -> tf.Tensor:
    import h5py

    # daos:// → DAOS VOL을 통해 직접 접근
    with h5py.File(path, 'r') as f:
        data = f["data"][()]
    return tf.convert_to_tensor(data.tobytes(), dtype=tf.string)

def _from_posix_as_bytes(path: str) -> tf.Tensor:
    with open(path, "rb") as f:
        buf = f.read()

    return tf.convert_to_tensor(buf, dtype=tf.string)

def _from_mpiio_as_bytes(path: str) -> tf.Tensor:
    from mpi4py import MPI

    meta_path = path + ".meta"
    dtype = np.float32  # default
    shape = None        # default

    if os.path.exists(meta_path):
        with open(meta_path, 'r') as metaf:
            meta = json.load(metaf)
            shape = tuple(meta.get("shape", (128, 128)))
            dtype_info = meta.get("dtype", "float32")
            # dtype이 잘못된 형식이면 str로 강제 변환
            if isinstance(dtype_info, (list, dict)):
                dtype_info = str(dtype_info)
            dtype = np.dtype(dtype_info)

    else:
        comm = MPI.COMM_SELF
        fh = MPI.File.Open(comm, path, MPI.MODE_RDONLY)
        fh.Seek(0, MPI.SEEK_END)
        size = fh.Get_position()
        count = size // np.dtype(dtype).itemsize
        shape = (count,)
        fh.Seek(0)
        buf = np.empty(count, dtype=dtype)
        fh.Read(buf)
        fh.Close()
        return tf.convert_to_tensor(buf.tobytes(), dtype=tf.string)

    # if meta exists, load as specified shape/dtype
    count = np.prod(shape)
    comm = MPI.COMM_SELF
    fh = MPI.File.Open(comm, path, MPI.MODE_RDONLY)
    buf = np.empty(count, dtype=dtype)
    fh.Read(buf)
    fh.Close()
    return tf.convert_to_tensor(buf.reshape(shape).tobytes(), dtype=tf.string)
