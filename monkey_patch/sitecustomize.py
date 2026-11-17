# monkey_patch/sitecustomize.py
# (FIXED: sys.modules-first lazy import + no meta_path recursion)

import os
import sys
import site
import builtins
import io
import importlib
import importlib.abc
import importlib.machinery
import threading

def _dbg(msg: str) -> None:
    if os.environ.get("DAOS_SITE_DEBUG", ""):
        print(f"[sitecustomize] {msg}", file=sys.stderr)

def _remove_user_site_paths() -> None:
    os.environ["PYTHONNOUSERSITE"] = "1"
    user_site = None
    try:
        user_site = site.getusersitepackages()
    except Exception:
        user_site = None

    new_path = []
    removed = []
    for p in list(sys.path):
        if not p:
            new_path.append(p)
            continue
        if ("/.local/" in p) or (user_site and p == user_site):
            removed.append(p)
            continue
        new_path.append(p)

    sys.path[:] = new_path
    if removed:
        _dbg(f"removed user-site paths: {removed}")

def _prepend_path(p: str) -> None:
    if p and p not in sys.path:
        sys.path.insert(0, p)

def _force_pydeps_sys_path() -> None:
    project_root = os.environ.get("PROJECT_ROOT", "")
    pydeps_plat = os.environ.get("PYDEPS_PLATLIB", "")
    pydeps_pure = os.environ.get("PYDEPS_PURELIB", "")

    _remove_user_site_paths()

    if project_root:
        _prepend_path(os.path.join(project_root, "monkey_patch"))

    _prepend_path(pydeps_pure)
    _prepend_path(pydeps_plat)
    _dbg(f"sys.path head: {sys.path[:8]}")

_force_pydeps_sys_path()

DAOS_MNT_ROOT    = "/mnt/daos/u"
POSIX_MNT_PREFIX = "/mnt/daos/u/posix"
HDF5_MNT_PREFIX  = "/mnt/daos/u/hdf5"

def _must_env(k: str) -> str:
    v = os.environ.get(k)
    if not v:
        raise RuntimeError(f"[DAOS ENV] {k} is missing. export {k}=... 해야 함.")
    return v

def _pool() -> str:
    return _must_env("DAOS_POOL")

def _hdf5_cont() -> str:
    return _must_env("DAOS_HDF5_CONT")

def is_daos_like_path(path: str) -> bool:
    return isinstance(path, str) and (path.startswith("daos://") or path.startswith("/mnt/daos/"))

def mnt_to_daos_hdf5(path: str) -> str:
    if not path.startswith(HDF5_MNT_PREFIX + "/"):
        raise ValueError(f"Expected HDF5 UNS path under {HDF5_MNT_PREFIX}: {path}")
    rel = path[len(HDF5_MNT_PREFIX) + 1 :]
    return f"daos://{_pool()}/{_hdf5_cont()}/{rel}"

_tf = None
_torch = None
_tf_io = None
_pt_io = None

def _lazy_import_tf():
    global _tf, _tf_io
    if _tf is None:
        m = sys.modules.get("tensorflow")
        if m is not None:
            _tf = m
        else:
            import tensorflow as tf  # noqa
            _tf = tf
    if _tf_io is None:
        m = sys.modules.get("tf_daos_io")
        if m is not None:
            _tf_io = m
        else:
            import tf_daos_io as tf_io  # noqa
            _tf_io = tf_io
    return _tf, _tf_io

def _lazy_import_torch():
    global _torch, _pt_io
    if _torch is None:
        m = sys.modules.get("torch")
        if m is not None:
            _torch = m
        else:
            import torch  # noqa
            _torch = torch
    if _pt_io is None:
        m = sys.modules.get("pt_daos_io")
        if m is not None:
            _pt_io = m
        else:
            import pt_daos_io as pt_io  # noqa
            _pt_io = pt_io
    return _torch, _pt_io

_ORIG_OPEN = builtins.open
_TF_TLS = threading.local()

def _patch_torch():
    if os.environ.get("DAOS_TORCH_PATCH", "1") in ("0", "false", "False"):
        _dbg("torch patch skipped (DAOS_TORCH_PATCH=0)")
        return
    torch, pt_io = _lazy_import_torch()
    if getattr(torch, "__DAOS_PATCHED__", False):
        return
    _orig_torch_load = torch.load

    def patched_open(path, mode="rb", *args, **kwargs):
        if not (isinstance(path, str) and mode.startswith("r")):
            return _ORIG_OPEN(path, mode, *args, **kwargs)
        ext = os.path.splitext(path)[1].lower()
        if ext in [".h5", ".hdf5"] and path.startswith(HDF5_MNT_PREFIX + "/"):
            daos_uri = mnt_to_daos_hdf5(path)
            t = pt_io._from_hdf5(daos_uri)
            return io.BytesIO(t.detach().cpu().numpy().tobytes())
        return _ORIG_OPEN(path, mode, *args, **kwargs)

    def patched_torch_load(path, *args, **kwargs):
        return _orig_torch_load(path, *args, **kwargs)

    builtins.open = patched_open
    torch.load = patched_torch_load
    torch.__DAOS_PATCHED__ = True
    _dbg("torch patches applied")

def _patch_tf():
    if os.environ.get("DAOS_TF_PATCH", "1") in ("0", "false", "False"):
        _dbg("tensorflow patch skipped (DAOS_TF_PATCH=0)")
        return
    tf, tf_io = _lazy_import_tf()
    if getattr(tf, "__DAOS_PATCHED__", False):
        return
    _orig_read_file = tf.io.read_file

    def _enter_tf():
        if getattr(_TF_TLS, "in_patch", False):
            return False
        _TF_TLS.in_patch = True
        return True

    def _exit_tf():
        _TF_TLS.in_patch = False

    def patched_read_file(path):
        if not _enter_tf():
            return _orig_read_file(path)
        try:
            if tf.is_tensor(path):
                if tf.executing_eagerly():
                    path = path.numpy().decode()
                else:
                    return _orig_read_file(path)
            if not isinstance(path, str):
                return _orig_read_file(path)
            ext = os.path.splitext(path)[1].lower()
            if ext in [".h5", ".hdf5"] and path.startswith(HDF5_MNT_PREFIX + "/"):
                daos_uri = mnt_to_daos_hdf5(path)
                return tf_io._from_hdf5_as_bytes(daos_uri)
            return _orig_read_file(path)
        finally:
            _exit_tf()

    tf.io.read_file = patched_read_file
    tf.__DAOS_PATCHED__ = True
    _dbg("tensorflow patches applied")

class _AutoPatchLoader(importlib.abc.Loader):
    def __init__(self, original_loader, root: str):
        self.original_loader = original_loader
        self.root = root

    def create_module(self, spec):
        if hasattr(self.original_loader, "create_module"):
            return self.original_loader.create_module(spec)
        return None

    def exec_module(self, module):
        self.original_loader.exec_module(module)
        if self.root == "tensorflow":
            _patch_tf()
        elif self.root == "torch":
            _patch_torch()

class _WrapLoaderFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname: str, path=None, target=None):
        if fullname not in ("tensorflow", "torch"):
            return None
        spec = importlib.machinery.PathFinder.find_spec(fullname, path)
        if spec and spec.loader:
            spec.loader = _AutoPatchLoader(spec.loader, fullname)
        return spec

sys.meta_path.insert(0, _WrapLoaderFinder())
_dbg("import hook installed (PathFinder-based, no recursion)")

if os.environ.get("DAOS_SITE_DEBUG", ""):
    try:
        import pip
        _dbg(f"pip file = {pip.__file__}")
    except Exception as e:
        _dbg(f"pip import failed: {e}")
