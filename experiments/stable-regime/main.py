import argparse
import json
import re
import os
import sys

import matplotlib.pyplot as plt

from enum import Enum
from typing import Tuple


class Errors(Enum):
    InvalidConfig = 1


def main():
    parser = argparse.ArgumentParser(
        prog="StableRegime",
        description="Given a full simulation trace, checks at which t the number of users stabilized.",
    )

    parser.add_argument("trace", help="File containing the trace")
    parser.add_argument("--bin_len", type=int, default=1)
    parser.add_argument("--window_size", type=int, default=50)
    parser.add_argument("--output", default="plots", help="Output directory for plots")
    parser.add_argument(
        "--threshold", type=float, default=0.01, help="Max % change for stability"
    )

    args = parser.parse_args()

    if not os.path.isdir(args.trace):
        print(f"Path {args.trace} is not a vaild dir")
        sys.exit(0)

    r = find_duration_and_warmup_time(args.trace)

    if isinstance(r, Enum):
        print("Something wrong")
        sys.exit(1)

    warmup_time, duration = r

    num_users = topology_size(args.trace)

    bins = duration // args.bin_len

    sessions_names = sessions_filenames(args.trace)

    os.makedirs(args.output, exist_ok=True)

    for session_file in sessions_names:
        print(session_file)
        online_users_per_bin = stable_regime(
            os.path.join(args.trace, session_file), warmup_time, bins, args.bin_len
        )
        if online_users_per_bin is None:
            print(f"Error in {session_file} uwu")
            continue

        if args.window_size > len(online_users_per_bin):
            print(f"window is too big for the run {session_file}")

        percentage_raw = [c / num_users * 100 for c in online_users_per_bin]
        obj = rolling_mean(
            percentage_raw,
            args.window_size,
            args.threshold,
            args.bin_len,
        )

        percentage_means, stable_at, stable_pct = obj

        plot_run(
            percentage_raw,
            percentage_means,
            stable_at,
            stable_pct,
            args.bin_len,
            args.window_size,
            session_file,
            args.output,
        )


def topology_size(trace_path: str) -> int:
    with open(os.path.join(trace_path, "user_distributions.ssv")) as users_dist:
        return len(users_dist.readlines())


def rolling_mean(
    online_users_per_bin: list[float], window_size: int, epsilon: float, bin_len: float
) -> tuple[list[float], float | None, float | None]:
    n = len(online_users_per_bin)
    if n <= window_size:
        return [], None, None
    means = [0.0 for _ in range(n - window_size)]
    stable_time: float | None = None
    stable_pct: float | None = None
    for w in range(len(means)):
        window = online_users_per_bin[w : w + window_size]
        means[w] = sum(window) / window_size
        if stable_time is None and max(window) - min(window) < epsilon:
            stable_time = (w + window_size / 2) * bin_len
            stable_pct = means[w]
    return means, stable_time, stable_pct


def stable_regime(
    session_path: str, warmup_time: float, duration: float, bin_len: float
) -> list[int] | None:

    num_bin = int((duration) // bin_len)  # no need to substract warmup time
    current_online_users = [0 for _ in range(num_bin)]

    prev_i = 0
    i = 0

    # second: open the sessions file
    with open(session_path, "r") as session_file:
        for line in session_file:
            session_event = json.loads(line)

            if "time" not in session_event:
                print(f"Run {session_path} han an entry without time in it.")
                break

            if session_event["time"] < warmup_time:
                continue

            i = int((session_event["time"] - warmup_time) // bin_len) - 1

            if prev_i != i:
                for j in range(prev_i + 1, i + 1):
                    current_online_users[j] = current_online_users[prev_i]
                prev_i = i

            if session_event["type"] == "start":
                current_online_users[i] += 1
            elif session_event["type"] in ["end", "end_boredom"]:
                current_online_users[i] -= 1
            else:
                print("this should not be possible uwu")

    # fill remaining bins after last event
    for j in range(prev_i, len(current_online_users)):
        current_online_users[j] = current_online_users[prev_i]

    return current_online_users


def sessions_filenames(trace_path: str) -> list[str]:
    return [
        f
        for f in os.listdir(trace_path)
        if re.match(r"^\d-session_trace\.jsonl", f) is not None
    ]


def find_duration_and_warmup_time(trace_path: str) -> Tuple[float, float] | Errors:
    # first: how much warmup did the simulation have? open the config json

    with open(os.path.join(trace_path, "used_config.json"), "r") as used_config_file:
        used_config_contents = json.load(used_config_file)

        if "warmup_time" not in used_config_contents:
            print("invalid file")
            return Errors.InvalidConfig

        if "duration" not in used_config_contents:
            print("invalid file")
            return Errors.InvalidConfig

        return used_config_contents["warmup_time"], used_config_contents["duration"]


def plot_run(
    percentage_raw: list[float],
    percentage_means: list[float],
    stable_at: float | None,
    stable_pct: float | None,
    bin_len: float,
    window_size: int,
    label: str,
    output_dir: str,
) -> None:
    fig, ax1 = plt.subplots(figsize=(10, 6))

    t_raw = [i * bin_len for i in range(len(percentage_raw))]
    ax1.plot(t_raw, percentage_raw, alpha=1, color="tab:blue", label="raw")

    t_mean = [(i + window_size / 2) * bin_len for i in range(len(percentage_means))]
    ax1.plot(t_mean, percentage_means, alpha=0.5, color="tab:red", label="rolling mean")

    ax1.set_xlabel("Time (s)")
    ax1.set_ylabel("% online users")
    ax1.set_title(label)
    if stable_at is not None:
        ax1.axvline(
            x=stable_at,
            color="tab:red",
            linestyle="--",
            label=f"stable ({stable_at:.0f}s, {stable_pct:.1f}%)",
        )
    ax1.legend()
    ax1.grid(True, alpha=0.3)
    fig.tight_layout()
    out = os.path.join(output_dir, f"{label}.png")
    fig.savefig(out)
    plt.close(fig)
    print(f"Saved {out}")


if __name__ == "__main__":
    main()
