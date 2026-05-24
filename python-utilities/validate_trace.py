#!/usr/bin/env python3
"""Validate BskySim trace files for internal consistency.

Checks: time monotonic, no duplicate event_id, global gen_id uniqueness,
no double-repost, session start/end alternation, and causality (no offline
actions, no time travel).

Usage:
    uv run validate_trace.py traces/
"""

import json
import argparse
import sys
from collections import defaultdict


def check_general_constraints(filepath):
    last_time = -1.0
    seen_event_ids = set()
    gen_ids = set()

    with open(filepath, "r") as f:
        for line_num, line in enumerate(f, 1):
            if not line.strip():
                continue
            data = json.loads(line)

            current_time = data["time"]
            if current_time < last_time:
                print(f"[x] {filepath} line {line_num}: time went backwards ({current_time} < {last_time})")
                return (False, None)
            last_time = current_time

            event_id = data["event_id"]
            if event_id in seen_event_ids:
                print(f"[x] {filepath} line {line_num}: duplicate event_id {event_id}")
                return (False, None)
            seen_event_ids.add(event_id)

            gen_ids.add(data["gen_id"])

    return (True, gen_ids)


def validate_create_trace(filepath):
    print(f"Create trace: {filepath}")
    valid, gen_ids = check_general_constraints(filepath)
    if not valid:
        return (False, None)

    seen_post_ids = set()
    with open(filepath, "r") as f:
        for line_num, line in enumerate(f, 1):
            if not line.strip():
                continue
            data = json.loads(line)
            post_id = data["post_id"]
            if post_id in seen_post_ids:
                print(f"[x] Create line {line_num}: duplicate post_id {post_id}")
                return (False, None)
            seen_post_ids.add(post_id)

    print("[v] Create trace OK")
    return (True, gen_ids)


def validate_action_trace(filepath):
    print(f"Action trace: {filepath}")
    valid, gen_ids = check_general_constraints(filepath)
    if not valid:
        return (False, None)

    seen_reposts = set()
    with open(filepath, "r") as f:
        for line_num, line in enumerate(f, 1):
            if not line.strip():
                continue
            data = json.loads(line)
            if data["type"] == "repost":
                pair = (data["user_id"], data["post_id"])
                if pair in seen_reposts:
                    print(f"[x] Action line {line_num}: user {data['user_id']} reposted post {data['post_id']} twice")
                    return (False, None)
                seen_reposts.add(pair)

    print("[v] Action trace OK")
    return (True, gen_ids)


def validate_session_trace(filepath):
    print(f"Session trace: {filepath}")
    valid, gen_ids = check_general_constraints(filepath)
    if not valid:
        return (False, None)

    user_state = {}
    with open(filepath, "r") as f:
        for line_num, line in enumerate(f, 1):
            if not line.strip():
                continue
            data = json.loads(line)
            uid = data["user_id"]
            stype = data["type"]
            if uid in user_state and user_state[uid] == stype:
                print(f"[x] Session line {line_num}: user {uid} consecutive '{stype}' without alternating")
                return (False, None)
            user_state[uid] = stype

    print("[v] Session trace OK")
    return (True, gen_ids)


def validate_propagate_trace(filepath):
    print(f"Propagate trace: {filepath}")
    valid, gen_ids = check_general_constraints(filepath)
    if not valid:
        return (False, None)
    print("[v] Propagate trace OK")
    return (True, gen_ids)


def validate_causality(create_path, action_path, session_path):
    print("Causality checks...")

    post_times = {}
    with open(create_path, "r") as f:
        for line in f:
            if not line.strip():
                continue
            d = json.loads(line)
            post_times[d["post_id"]] = d["time"]

    events = []
    with open(session_path, "r") as f:
        for line in f:
            if not line.strip():
                continue
            d = json.loads(line)
            events.append({"time": d["time"], "kind": "session", "user_id": d["user_id"], "type": d["type"]})
    with open(action_path, "r") as f:
        for line in f:
            if not line.strip():
                continue
            d = json.loads(line)
            events.append({"time": d["time"], "kind": "action", "user_id": d["user_id"], "post_id": d["post_id"], "type": d["type"]})

    events.sort(key=lambda e: (e["time"], 0 if e["kind"] == "session" else 1))

    online = defaultdict(bool)
    for e in events:
        uid = e["user_id"]
        if e["kind"] == "session":
            online[uid] = (e["type"] == "start")
        else:
            if not online[uid]:
                print(f"[x] Causality: user {uid} acted '{e['type']}' while OFFLINE at t={e['time']}")
                return False
            pid = e["post_id"]
            ct = post_times.get(pid)
            if ct is None:
                print(f"[x] Causality: action on post {pid} at t={e['time']}, but post was never created")
                return False
            if e["time"] < ct:
                print(f"[x] Causality: action on post {pid} at t={e['time']} before creation at t={ct}")
                return False

    print("[v] Causality OK")
    return True


def main():
    parser = argparse.ArgumentParser(description="Validate BskySim trace files")
    parser.add_argument("folder", type=str, help="Folder containing create/action/session/propagate trace JSONL files")
    args = parser.parse_args()

    import os
    folder = args.folder
    if not os.path.isdir(folder):
        print(f"Error: '{folder}' is not a directory", file=sys.stderr)
        sys.exit(1)

    def f(name):
        return os.path.join(folder, name)

    c_ok, c_gen = validate_create_trace(f("create_trace.jsonl"))
    a_ok, a_gen = validate_action_trace(f("action_trace.jsonl"))
    s_ok, s_gen = validate_session_trace(f("session_trace.jsonl"))
    p_ok, p_gen = validate_propagate_trace(f("propagate_trace.jsonl"))

    # Cross-file gen_id uniqueness
    gid_ok = True
    if all([c_ok, a_ok, s_ok, p_ok]):
        seen = {}
        for name, gset in [("create", c_gen), ("action", a_gen), ("session", s_gen), ("propagate", p_gen)]:
            for gid in gset:
                if gid in seen:
                    print(f"[x] Global gen_id: {gid} in both {seen[gid]} and {name}")
                    gid_ok = False
                seen[gid] = name

    causality_ok = validate_causality(f("create_trace.jsonl"), f("action_trace.jsonl"), f("session_trace.jsonl"))

    print("\n--- Summary ---")
    all_ok = all([c_ok, a_ok, s_ok, p_ok, gid_ok, causality_ok])
    if all_ok:
        print("[v] All traces valid!")
    else:
        print("[x] Failures detected")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
