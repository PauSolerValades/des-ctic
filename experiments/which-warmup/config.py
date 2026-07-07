"""Shared configuration and CLI argument parsing for the warmup experiment."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Config:
    """Resolved configuration for warmup analysis."""

    traces_dir: Path
    cascades_dir: Path
    datasets_dir: Path
    output_dir: Path
    warmups: list[float]
    num_runs: int
    bin_size: int = 50


# ---------------------------------------------------------------------------
# Discovery helpers
# ---------------------------------------------------------------------------

_TICKS_RE = re.compile(r"^(\d+(?:\.\d+)?)-ticks$")


def discover_warmups(traces_dir: Path) -> list[float]:
    """Scan *traces_dir* for subdirectories named ``{N}-ticks`` and return
    the sorted list of warmup values."""
    warmups: list[float] = []
    if not traces_dir.is_dir():
        raise FileNotFoundError(f"Traces directory not found: {traces_dir}")

    for entry in sorted(traces_dir.iterdir()):
        if not entry.is_dir():
            continue
        m = _TICKS_RE.match(entry.name)
        if m:
            warmups.append(float(m.group(1)))

    if not warmups:
        raise ValueError(f"No warmup directories ({{N}}-ticks) found in {traces_dir}")

    return sorted(warmups)


def discover_num_runs(traces_dir: Path, warmup: float) -> int:
    """Count how many ``{N}-session_trace.jsonl`` files exist for a given
    warmup value."""
    ticks_dir = traces_dir / f"{warmup:g}-ticks"
    count = 0
    if ticks_dir.is_dir():
        for f in ticks_dir.iterdir():
            if f.name.endswith("-session_trace.jsonl"):
                count += 1
    return count
