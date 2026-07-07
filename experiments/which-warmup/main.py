#!/usr/bin/env python3
"""Warmup experiment analysis — entry point.

Usage:
    python main.py table --traces ../../traces/10K-warmup \\
                         --cascades ../../cascades/10K-warmup \\
                         --datasets ../../datasets/10K-warmup

    python main.py plots --traces ../../traces/10K-warmup \\
                         --cascades ../../cascades/10K-warmup \\
                         --datasets ../../datasets/10K-warmup

    python main.py all --traces ../../traces/10K-warmup \\
                       --cascades ../../cascades/10K-warmup \\
                       --datasets ../../datasets/10K-warmup
"""

from __future__ import annotations

import argparse

import build_table
import temporal_analysis
import utils
from utils import Config
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Warmup experiment analysis tools.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("table", help="Generate the summary table.")
    sub.add_parser("plots", help="Generate all temporal analysis plots.")
    sub.add_parser("all", help="Run both table and plots.")

    args, remaining = parser.parse_known_args()

    parser.add_argument(
        "--traces",
        type=Path,
        required=True,
        help="Directory containing {N}-ticks/ subdirectories with trace files.",
    )
    parser.add_argument(
        "--cascades",
        type=Path,
        required=True,
        help="Directory containing warmup-{N}.ssv cascade files.",
    )
    parser.add_argument(
        "--datasets",
        type=Path,
        required=True,
        help="Directory containing warmup-{N}/ subdirectories with dataset files.",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("output"),
        help="Output directory for results (default: output/).",
    )
    parser.add_argument(
        "--num-runs",
        "-n",
        type=int,
        default=None,
        help="Number of runs per warmup (auto-detected if not specified).",
    )
    parser.add_argument(
        "--bin-size",
        type=int,
        default=50,
        help="Bin size in ticks for time-series plots (default: 50).",
    )

    subargs = sub.

    traces_dir: Path = args.traces.resolve()
    cascades_dir: Path = args.cascades.resolve()
    datasets_dir: Path = args.datasets.resolve()
    output_dir: Path = args.output.resolve()

    warmups = utils.discover_warmups(traces_dir)
    num_runs = args.num_runs or utils.discover_num_runs(traces_dir, warmups[0])

    if num_runs == 0:
        print(f"Number of runs ({num_runs}) is zero, illegal behaviour :(")
        return

    config = Config(
        traces_dir=traces_dir,
        cascades_dir=cascades_dir,
        datasets_dir=datasets_dir,
        output_dir=output_dir,
        warmups=warmups,
        num_runs=num_runs,
        bin_size=args.bin_size,
    )

    if args.command == "table":
        build_table.main(config)
    elif args.command == "plots":
        temporal_analysis.main(config)
    elif args.command == "all":
        build_table.main(config)
        temporal_analysis.main(config)


if __name__ == "__main__":
    main()
