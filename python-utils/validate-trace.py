#!/usr/bin/env python3
"""Validate BskySim trace files for internal consistency.

Checks: time monotonic, no duplicate event_id, global gen_id uniqueness,
no double-repost, session start/end alternation, causality (no offline
actions, no time travel), and swap trace integrity.

Usage:
    uv run validate_trace.py traces/
"""

import json
import argparse
import sys
import os
from collections import defaultdict


VALID_SWAP_REASONS = {"simulation_start", "session_start", "refresh"}


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
                print(
                    f"[x] {filepath} line {line_num}: time went backwards ({current_time} < {last_time})"
                )
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

            # parent_id must be present and a valid u32
            parent_id = data.get("parent_id")
            if parent_id is None:
                print(f"[x] Action line {line_num}: missing parent_id")
                return (False, None)
            if not isinstance(parent_id, int) or parent_id < 0:
                print(f"[x] Action line {line_num}: invalid parent_id {parent_id}")
                return (False, None)

            if data["type"] == "repost":
                pair = (data["user_id"], data["post_id"])
                if pair in seen_reposts:
                    print(
                        f"[x] Action line {line_num}: user {data['user_id']} reposted post {data['post_id']} twice"
                    )
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
            # end_boredom is a valid session type — same as regular "end"
            if uid in user_state and user_state[uid] == stype:
                print(
                    f"[x] Session line {line_num}: user {uid} consecutive '{stype}' without alternating"
                )
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


def validate_swap_trace(filepath):
    """Validate swap trace. Swaps are consequences, not events — no event_id or gen_id."""
    print(f"Swap trace: {filepath}")
    last_time = -1.0

    with open(filepath, "r") as f:
        for line_num, line in enumerate(f, 1):
            if not line.strip():
                continue
            data = json.loads(line)

            current_time = data["time"]
            if current_time < last_time:
                print(
                    f"[x] {filepath} line {line_num}: time went backwards ({current_time} < {last_time})"
                )
                return False
            last_time = current_time

            reason = data.get("reason")
            if reason not in VALID_SWAP_REASONS:
                print(
                    f"[x] Swap line {line_num}: invalid reason '{reason}' (expected one of {VALID_SWAP_REASONS})"
                )
                return False

            # user_id must be present
            if "user_id" not in data:
                print(f"[x] Swap line {line_num}: missing user_id")
                return False

    print("[v] Swap trace OK")
    return True


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
            events.append(
                {
                    "time": d["time"],
                    "kind": "session",
                    "user_id": d["user_id"],
                    "type": d["type"],
                }
            )
    with open(action_path, "r") as f:
        for line in f:
            if not line.strip():
                continue
            d = json.loads(line)
            events.append(
                {
                    "time": d["time"],
                    "kind": "action",
                    "user_id": d["user_id"],
                    "post_id": d["post_id"],
                    "type": d["type"],
                }
            )

    events.sort(key=lambda e: (e["time"], 0 if e["kind"] == "session" else 1))

    online = defaultdict(bool)
    for e in events:
        uid = e["user_id"]
        if e["kind"] == "session":
            online[uid] = e["type"] == "start"
        else:
            if not online[uid]:
                print(
                    f"[x] Causality: user {uid} acted '{e['type']}' while OFFLINE at t={e['time']}"
                )
                return False
            pid = e["post_id"]
            ct = post_times.get(pid)
            if ct is None:
                print(
                    f"[x] Causality: action on post {pid} at t={e['time']}, but post was never created"
                )
                return False
            if e["time"] < ct:
                print(
                    f"[x] Causality: action on post {pid} at t={e['time']} before creation at t={ct}"
                )
                return False

    print("[v] Causality OK")
    return True


def validate_repost_chain(create_path, action_path):
    """Every repost's (parent_id, post_id) must have been created or reposted earlier."""
    print("Repost chain checks...")

    # (user_id, post_id) pairs for all confirmed creates/reposts
    authored: set[tuple[int, int]] = set()

    # Load creates first — they are the roots
    create_events = []
    with open(create_path, "r") as f:
        for line in f:
            if not line.strip():
                continue
            d = json.loads(line)
            create_events.append((d["time"], d["user_id"], d["post_id"]))

    # Load actions
    action_events = []
    with open(action_path, "r") as f:
        for line in f:
            if not line.strip():
                continue
            d = json.loads(line)
            action_events.append((
                d["time"],
                d["user_id"],
                d["post_id"],
                d["parent_id"],
                d["type"],
            ))

    # Sort creates first (at same time), then actions
    all_events = [(t, 0, uid, pid, None, None) for t, uid, pid in create_events]
    all_events += [(t, 1, uid, pid, parent_id, atype) for t, uid, pid, parent_id, atype in action_events]
    all_events.sort(key=lambda e: (e[0], e[1]))

    for ev in all_events:
        _, kind, uid, pid, parent_id, atype = ev
        if kind == 0:
            # Create: user authored the post
            authored.add((uid, pid))
        else:
            # Action: check parent chain for reposts
            if atype == "repost":
                if (parent_id, pid) not in authored:
                    print(
                        f"[x] Repost chain: user {uid} reposted post {pid} via parent {parent_id}, "
                        f"but parent {parent_id} never created or reposted post {pid}"
                    )
                    return False
            # Any action (including repost itself) confirms the user saw/exposed the post.
            # A repost adds the user as a valid future parent.
            if atype == "repost":
                authored.add((uid, pid))

    print("[v] Repost chain OK")
    return True
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
            events.append(
                {
                    "time": d["time"],
                    "kind": "session",
                    "user_id": d["user_id"],
                    "type": d["type"],
                }
            )
    with open(action_path, "r") as f:
        for line in f:
            if not line.strip():
                continue
            d = json.loads(line)
            events.append(
                {
                    "time": d["time"],
                    "kind": "action",
                    "user_id": d["user_id"],
                    "post_id": d["post_id"],
                    "type": d["type"],
                }
            )

    events.sort(key=lambda e: (e["time"], 0 if e["kind"] == "session" else 1))

    online = defaultdict(bool)
    for e in events:
        uid = e["user_id"]
        if e["kind"] == "session":
            online[uid] = e["type"] == "start"
        else:
            if not online[uid]:
                print(
                    f"[x] Causality: user {uid} acted '{e['type']}' while OFFLINE at t={e['time']}"
                )
                return False
            pid = e["post_id"]
            ct = post_times.get(pid)
            if ct is None:
                print(
                    f"[x] Causality: action on post {pid} at t={e['time']}, but post was never created"
                )
                return False
            if e["time"] < ct:
                print(
                    f"[x] Causality: action on post {pid} at t={e['time']} before creation at t={ct}"
                )
                return False

    print("[v] Causality OK")
    return True


def main():
    parser = argparse.ArgumentParser(description="Validate BskySim trace files")
    parser.add_argument(
        "folder",
        type=str,
        help="Folder containing create/action/session/propagate/swap trace JSONL files",
    )
    args = parser.parse_args()

    folder = args.folder
    if not os.path.isdir(folder):
        print(f"Error: '{folder}' is not a directory", file=sys.stderr)
        sys.exit(1)

    results = {}

    def find_trace(name):
        """Find a trace file in folder. Tries bare name first, then *-{name} pattern."""
        bare = os.path.join(folder, name)
        if os.path.exists(bare):
            return bare
        # Look for run-prefixed files: {run}-{name}
        for entry in os.listdir(folder):
            if entry.endswith("-" + name):
                return os.path.join(folder, entry)
        return bare  # let the open() call produce a clear error

    c_ok, c_gen = validate_create_trace(find_trace("create_trace.jsonl"))
    results["create"] = c_ok
    a_ok, a_gen = validate_action_trace(find_trace("action_trace.jsonl"))
    results["action"] = a_ok
    s_ok, s_gen = validate_session_trace(find_trace("session_trace.jsonl"))
    results["session"] = s_ok
    p_ok, p_gen = validate_propagate_trace(find_trace("propagate_trace.jsonl"))
    results["propagate"] = p_ok

    swap_path = find_trace("swap_trace.jsonl")
    sw_ok = True
    if os.path.exists(swap_path):
        sw_ok = validate_swap_trace(swap_path)
    results["swap"] = sw_ok

    # Cross-file gen_id uniqueness.
    # Boredom session-ends borrow the gen_id from the action that triggered them,
    # so gen_ids naturally overlap between session and action traces.
    gid_ok = True
    if all([c_ok, a_ok, s_ok, p_ok]):
        seen = {}
        # Check create vs action (should never overlap)
        for gid in (c_gen or set()):
            seen[gid] = "create"
        for name, gset in [
            ("propagate", p_gen or set()),
            ("action", a_gen or set()),
        ]:
            for gid in gset:
                if gid in seen:
                    print(f"[x] Global gen_id: {gid} in both {seen[gid]} and {name}")
                    gid_ok = False
                seen[gid] = name

        # Session gen_ids: allow overlap with action (boredom ends),
        # but flag overlaps with create or propagate.
        for gid in (s_gen or set()):
            if gid in seen and seen[gid] not in ("action",):
                print(f"[x] Global gen_id: {gid} in both {seen[gid]} and session")
                gid_ok = False
            # Don't add to 'seen' — allow duplicates with action

    causality_ok = validate_causality(
        find_trace("create_trace.jsonl"),
        find_trace("action_trace.jsonl"),
        find_trace("session_trace.jsonl"),
    )

    chain_ok = validate_repost_chain(
        find_trace("create_trace.jsonl"),
        find_trace("action_trace.jsonl"),
    )

    print("\n--- Summary ---")
    all_ok = all(list(results.values()) + [gid_ok, causality_ok, chain_ok])
    if all_ok:
        print("[v] All traces valid!")
    else:
        print("[x] Failures detected")
        for name, ok in results.items():
            if not ok:
                print(f"    {name} trace: FAILED")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
