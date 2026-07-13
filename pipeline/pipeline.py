#!/usr/bin/env python3
"""Pipeline: bskysim → construct-cascades → dataset-creation.

Usage:
    python pipeline.py my-experiment.toml
    python pipeline.py my-experiment.toml --dry-run
"""

import argparse
import glob
import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent  # project root — all CWD-relative paths start here


def run(cmd: list[str], cwd: Path | None = None, **kwargs) -> subprocess.CompletedProcess:
    """Print + run a command. Dies on non-zero exit."""
    print(f"  \033[36m{' '.join(cmd)}\033[0m")
    return subprocess.run(cmd, check=True, cwd=cwd, **kwargs)


def extract_likes(traces_dir: Path, output_path: Path) -> None:
    """Extract likes from *-action_trace.jsonl into an SSV file."""
    action_files = sorted(traces_dir.glob("*-action_trace.jsonl"))
    header = "run_id post_id user_id parent_id type time\n"
    count = 0
    with open(output_path, "w") as out:
        out.write(header)
        for af in action_files:
            run_id = af.name.split("-")[0]
            with open(af) as fh:
                for line in fh:
                    row = json.loads(line)
                    if row.get("type") != "like":
                        continue
                    out.write(
                        f"{run_id} {row['post_id']} {row['user_id']} "
                        f"{row['parent_id']} like {row['time']}\n"
                    )
                    count += 1
    print(f"  Extracted {count} likes → {output_path}")


# ---------------------------------------------------------------------------
# Pipeline steps
# ---------------------------------------------------------------------------

def step_simulate(binary: str, data: str, config: str, output: str,
                  runs: int, workers: int) -> None:
    """Run bskysim. Options before positional args (POSIX).
    CWD must be the bskysim project dir (params/, data/ live there)."""
    bskysim_dir = Path(binary).resolve().parent.parent.parent  # zig-out/bin/ → bskysim/
    (ROOT / output).mkdir(parents=True, exist_ok=True)
    # All paths relative to bskysim project dir
    data_rel = os.path.relpath(ROOT / data, bskysim_dir)
    config_rel = os.path.relpath(ROOT / config, bskysim_dir)
    output_rel = os.path.relpath(ROOT / output, bskysim_dir)
    run([binary,
         "-o", output_rel, "-n", str(runs), "-w", str(workers),
         data_rel, config_rel],
        cwd=bskysim_dir)


def step_cascades(binary: str, traces: str, output: str,
                  buckets: int = 256, temp: str = "/tmp/cascade-building") -> None:
    """Run construct-cascade. Options before positional args (POSIX). CWD = project root."""
    (ROOT / output).parent.mkdir(parents=True, exist_ok=True)
    run([binary,
         "-o", output, "-b", str(buckets), "-p", temp,
         traces],
        cwd=ROOT)


def step_datasets(binary: str, cascades: str, likes: str,
                  traces: str, output: str) -> None:
    """Run dataset-creation (Go binary, handles paths normally)."""
    (ROOT / output).mkdir(parents=True, exist_ok=True)
    run([binary, "-output", output, cascades, likes, traces, "all"])


# ---------------------------------------------------------------------------
# Config handling
# ---------------------------------------------------------------------------

def expand_configs(raw: list[dict]) -> list[dict]:
    """Expand glob patterns. Name defaults to stem."""
    expanded = []
    for entry in raw:
        pattern = entry.get("pattern")
        if pattern:
            for p in sorted(glob.glob(pattern, recursive=True)):
                name = entry.get("name", Path(p).stem)
                expanded.append({"name": name, "path": p})
        else:
            expanded.append(entry)
    return expanded


def main():
    parser = argparse.ArgumentParser(description="Run the simulation → dataset pipeline.")
    parser.add_argument("config", type=Path, help="TOML config file")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--only", type=str, help="Run only this config name")
    args = parser.parse_args()

    with open(args.config, "rb") as f:
        cfg = tomllib.load(f)

    # Resolve paths against the config file's directory
    base = args.config.resolve().parent
    def rel(p: str) -> str:
        """Resolve a path relative to the config file, then make it relative
        to ROOT so bskysim/construct-cascade can use it as cwd=ROOT."""
        return str((base / p).resolve().relative_to(ROOT))

    bskysim         = str((base / cfg.get("bskysim", "../bskysim/zig-out/bin/bskysim")).resolve())
    construct_cascade = str((base / cfg.get("construct_cascade", "../construct-cascades/zig-out/bin/construct-cascade")).resolve())
    dataset_creation  = str((base / cfg.get("dataset_creation", "../dataset-creation/dataset-creation")).resolve())

    data_file = rel(cfg["data"])
    runs = cfg["runs"]
    workers = cfg["workers"]

    traces_root   = cfg.get("traces_dir", "traces")
    cascades_root = cfg.get("cascades_dir", "cascades")
    datasets_root = cfg.get("datasets_dir", "datasets")
    temp_dir = cfg.get("temp_dir", "/tmp/cascade-building")
    buckets  = cfg.get("buckets", 256)

    configs = expand_configs(cfg["configs"])

    if args.only:
        configs = [c for c in configs if c["name"] == args.only]
        if not configs:
            print(f"Config '{args.only}' not found.")
            sys.exit(1)

    for i, c in enumerate(configs):
        name = c["name"]
        sim_config = rel(c["path"])
        print(f"\n\033[1m[{i+1}/{len(configs)}] {name}\033[0m")

        traces   = f"{traces_root}/{name}"
        cascades = f"{cascades_root}/{name}.ssv"
        likes    = f"{traces}/{name}-likes.ssv"
        datasets = f"{datasets_root}/{name}"

        if args.dry_run:
            print(f"  traces:   {ROOT / traces}")
            print(f"  cascades: {ROOT / cascades}")
            print(f"  datasets: {ROOT / datasets}")
            continue

        print("  [1/3] Simulating...")
        step_simulate(bskysim, data_file, sim_config, traces, runs, workers)

        print("  [2/3] Building cascades...")
        step_cascades(construct_cascade, traces, cascades, buckets, temp_dir)

        extract_likes(ROOT / traces, ROOT / likes)

        print("  [3/3] Creating datasets...")
        step_datasets(dataset_creation,
                      str(ROOT / cascades),
                      str(ROOT / likes),
                      str(ROOT / traces),
                      str(ROOT / datasets))

        print(f"  \033[32mDone: {name}\033[0m")

    print(f"\n\033[32mAll {len(configs)} configs complete.\033[0m")


if __name__ == "__main__":
    main()
