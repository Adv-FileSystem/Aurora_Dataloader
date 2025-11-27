# sitecustomize.py (통합 버전)
import os
import sys
import types

# 둘 다 import 가능해야 하므로 try 블록이 아닌 전역 import
import tensorflow as tf
import torch
import builtins
import io

original_open = builtins.open
original_torch_load = torch.load

# TensorFlow용 모듈 import
import tf_daos_io as tf_io

# PyTorch용 모듈 import (함수명이 중복되지 않게 pt_ 접두어 사용한다고 가정)
import pt_daos_io as pt_io

##########################
# TensorFlow Monkey Patch
##########################

_orig_read_file = tf.io.read_file
_orig_image_dataset_from_directory = tf.keras.utils.image_dataset_from_directory
_orig_TextLineDataset = tf.data.TextLineDataset
_orig_TFRecordDataset = tf.data.TFRecordDataset
_orig_FixedLengthRecordDataset = tf.data.FixedLengthRecordDataset

def is_daos_path(path: str) -> bool:
    if isinstance(path, tf.Tensor):
        return tf.logical_or(
            tf.strings.regex_full_match(path, r"^daos://.*"),
            tf.strings.regex_full_match(path, r"^/mnt/daos/.*")
        )
    else:
        return path.startswith("daos://") or path.startswith("/mnt/daos/")

def mnt_to_daos(path: str) -> str:
    if isinstance(path, tf.Tensor):
        is_mnt = tf.strings.regex_full_match(path, r"^/mnt/daos/.*")
        def convert():
            relative = tf.strings.substr(path, len("/mnt/daos/"), -1)
            pool = tf.constant(os.environ.get("DAOS_POOL"), dtype=tf.string)
            cont = tf.constant(os.environ.get("DAOS_CONT"), dtype=tf.string)
            return tf.strings.join(["daos://", pool, "/", cont, "/", relative])
        return tf.cond(is_mnt, convert, lambda: path)
    else:
        if path.startswith("/mnt/daos/"):
            relative = path[len("/mnt/daos/"):]
            pool = os.environ.get("DAOS_POOL")
            cont = os.environ.get("DAOS_CONT")
            return f"daos://{pool}/{cont}/{relative}"
        return path

def to_mnt_path(path: str) -> str:
    if path.startswith("daos://"):
        return "/mnt/daos/" + path.split("/")[-1]
    if "/mnt/daos/" not in path:
        return "/mnt/daos/" + path
    return path

def tf_convert_filenames(filenames):
    if isinstance(filenames, (str, tf.Tensor)):
        filenames = [filenames]
    converted = []
    for f in filenames:
        path = f.numpy().decode() if tf.is_tensor(f) else f
        if is_daos_path(path):
            ext = os.path.splitext(path)[-1]
            if ext == ".h5":
                path = mnt_to_daos(path)
                data = tf_io._from_hdf5_as_bytes(path)
            elif ext in [".mpi", ".dat", ".bin"]:
                data = tf_io._from_mpiio_as_bytes(path)
            else:
                rel_path = to_mnt_path(path)
                data = tf_io._from_posix_as_bytes(rel_path)
            converted.append(data)
        else:
            converted.append(tf.io.read_file(path))
    return tf.data.Dataset.from_tensor_slices(converted)

def patched_read_file(path):
    if tf.is_tensor(path):
        path = tf.strings.strip(path)
        if tf.executing_eagerly():
            path = path.numpy().decode()
        else:
            return _orig_read_file(path)
    if not is_daos_path(path):
        return _orig_read_file(path)
    if path.endswith(".h5"):
        path = mnt_to_daos(path)
        return tf_io._from_hdf5_as_bytes(path)
    elif path.endswith(".mpi") or path.endswith(".bin") or path.endswith(".dat"):
        path = mnt_to_daos(path)
        return tf_io._from_mpiio_as_bytes(path)
    else:
        rel_path = to_mnt_path(path)
        return tf_io._from_posix_as_bytes(rel_path)

def patched_image_dataset_from_directory(*args, **kwargs):
    directory = args[0] if args else kwargs.get("directory", None)
    if directory and is_daos_path(directory):
        directory = mnt_to_daos(directory)
        args = (directory,) + args[1:]
    return _orig_image_dataset_from_directory(*args, **kwargs)

class PatchedTextLineDataset(tf.data.Dataset):
    def __new__(cls, filenames, *args, **kwargs):
        return tf_convert_filenames(filenames).map(lambda x: tf.strings.strip(x))

class PatchedTFRecordDataset(tf.data.Dataset):
    def __new__(cls, filenames, *args, **kwargs):
        return tf_convert_filenames(filenames)

class PatchedFixedLengthRecordDataset(tf.data.Dataset):
    def __new__(cls, filenames, *args, **kwargs):
        return tf_convert_filenames(filenames)

# TensorFlow monkey patch
if "tensorflow" in sys.modules:
    tf.keras.utils.image_dataset_from_directory = patched_image_dataset_from_directory
    tf.io.read_file = patched_read_file
    tf.data.TextLineDataset = PatchedTextLineDataset
    tf.data.TFRecordDataset = PatchedTFRecordDataset
    tf.data.FixedLengthRecordDataset = PatchedFixedLengthRecordDataset

##########################
# PyTorch Monkey Patch
##########################

_orig_open = builtins.open
_orig_torch_load = torch.load

def patched_open(path, mode='rb', *args, **kwargs):
    if isinstance(path, str) and is_daos_path(path) and mode == 'rb':
        ext = path.split('.')[-1]
        if ext in ['h5', 'hdf5']:
            tensor = pt_io._from_hdf5(mnt_to_daos(path))
        elif ext in ['mpi', 'bin', 'dat']:
            tensor = pt_io._from_mpiio(mnt_to_daos(path))
        else:
            tensor = pt_io._from_posix(to_mnt_path(path))
        if isinstance(tensor, torch.Tensor):
            return io.BytesIO(tensor.numpy().tobytes())
    return _orig_open(path, mode, *args, **kwargs)

def patched_torch_load(path, *args, **kwargs):
    if isinstance(path, str) and is_daos_path(path):
        ext = path.split(".")[-1]
        if ext in ["h5", "hdf5"]:
            tensor = pt_io._from_hdf5(mnt_to_daos(path))
        elif ext in ["mpi", "bin", "dat", "raw"]:  # ← raw 추가
            tensor = pt_io._from_mpiio(mnt_to_daos(path))
        else:
            tensor = pt_io._from_posix(to_mnt_path(path))
        # ⛔ torch.load()는 state_dict 형태가 아니면 여기서 바로 반환
        return tensor
    return _orig_torch_load(path, *args, **kwargs)


if "torch" in sys.modules:
    builtins.open = patched_open
    torch.load = patched_torch_load

