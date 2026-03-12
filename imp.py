"""Compatibility shim for the removed stdlib ``imp`` module on Python >= 3.12.

This repository still carries Waf 2.0.18, which imports ``imp`` and uses:
  - imp.new_module(...)
  - imp.get_tag()

Provide those APIs (plus a minimal load_source helper) so Waf can run on
modern Python versions without changing vendored Waf internals.
"""

from __future__ import annotations

import importlib.util
import sys
import types
from types import ModuleType


def new_module(name: str) -> ModuleType:
    """Return a new empty module object with the given name."""
    return types.ModuleType(name)


def get_tag() -> str:
    """Return the interpreter cache tag, equivalent to historic imp.get_tag()."""
    tag = getattr(sys.implementation, "cache_tag", None)
    if not tag:
        raise AttributeError("cache tag is unavailable for this interpreter")
    return tag


def load_source(name: str, pathname: str, file=None) -> ModuleType:
    """Load and return a module from source at ``pathname``."""
    spec = importlib.util.spec_from_file_location(name, pathname)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load source module {name!r} from {pathname!r}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module
