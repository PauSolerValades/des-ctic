import os
import argparse
import sys
import subprocess


def main():
    parser = argparse.ArgumentParser(
        prog="StableRegimeExperiment",
        description="Runs the full experment to find the stable regime in the simulation",
    )

    parser.add_argument(
        "experiment", help="Direcotry containing the directories containing the traces"
    )
    parser.add_argument("--bin_len", type=int, default=1)
    parser.add_argument("--window_size", type=int, default=50)
    parser.add_argument("--output", default="plots", help="Output directory for plots")
    parser.add_argument(
        "--threshold", type=float, default=0.01, help="Max % change for stability"
    )

    args = parser.parse_args()

    if not os.path.isdir(args.experiment):
        print(f"Path {args.experiment} is not a vaild dir")
        sys.exit(0)

    for trace_dir in os.listdir(args.experiment):
        subprocess.run(
            [
                "uv",
                "run",
                "main.py",
                "--output",
                os.path.join("output", trace_dir) + "/",
                "--bin_len",
                str(args.bin_len),
                "--window_size",
                str(args.window_size),
                "--threshold",
                str(args.threshold),
                os.path.join(args.experiment, trace_dir),
            ]
        )


if __name__ == "__main__":
    main()
