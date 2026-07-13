#!/usr/bin/env python3
"""Run the warmup analysis for one or more experiments.

Usage:
    python run_all_experiments.py ../../traces/10K-warmup ../../cascades/10K-warmup ../../datasets/10K-warmup
    python run_all_experiments.py \\
        ../../traces/10K-warmup ../../cascades/10K-warmup ../../datasets/10K-warmup \\
        ../../traces/10K_n100 ../../cascades/10K_n100 ../../datasets/10K_n100 \\
        -o output
"""

import argparse
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="WarmupExperiment",
        description="Runs warmup analysis for each traces/cascades/datasets triple.",
    )
    parser.add_argument(
        "dirs",
        nargs="+",
        help="Traces, cascades, and datasets directories per experiment, in threes.",
    )
    parser.add_argument(
        "--output",
        "-o",
        default="output",
        help="Output root (experiment dir name used as subdir, default: output/).",
    )
    parser.add_argument(
        "--num-runs",
        "-n",
        type=int,
        default=None,
        help="Number of runs per warmup (auto-detected if not given).",
    )
    parser.add_argument(
        "--bin-size",
        type=int,
        default=50,
        help="Bin size in ticks for time-series plots (default: 50).",
    )

    args = parser.parse_args()

    if len(args.dirs) % 3 != 0:
        parser.error("Expected traces/cascades/datasets in groups of three.")

    for i in range(0, len(args.dirs), 3):
        traces, cascades, datasets = args.dirs[i], args.dirs[i + 1], args.dirs[i + 2]
        exp_name = traces.rstrip("/").rsplit("/", 1)[-1]
        output = f"{args.output}/{exp_name}"

        cmd = [
            "uv",
            "run",
            "main.py",
            "all",
            traces,
            cascades,
            datasets,
            "--output",
            output,
            "--bin-size",
            str(args.bin_size),
        ]
        if args.num_runs is not None:
            cmd.extend(["--num-runs", str(args.num_runs)])

        print(f"[{exp_name}] {' '.join(cmd)}\n")
        subprocess.run(cmd)
        print()


if __name__ == "__main__":
    main()
