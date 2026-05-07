#!/usr/bin/env python3
"""Remove project IAM bindings whose principals are 'deleted:' (ghost members).

Background: when a service account is deleted (manually or by terraform), its
project-level IAM bindings remain as `deleted:serviceAccount:<email>?uid=<id>`
entries. These accumulate across deploy/destroy cycles. We observed two distinct
UIDs for the same SA email after a single re-deploy.

This script does a single set-iam-policy call (atomic; survives conditional
bindings) to remove all such ghost members.

Usage: clean-orphan-iam-bindings.py <PROJECT_ID>
"""
import json
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <PROJECT_ID>", file=sys.stderr)
        return 2
    project = sys.argv[1]

    out = subprocess.run(
        ["gcloud", "projects", "get-iam-policy", project, "--format=json"],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(out.stdout)

    removed = 0
    for b in data["bindings"]:
        n0 = len(b["members"])
        b["members"] = [m for m in b["members"] if not m.startswith("deleted:")]
        removed += n0 - len(b["members"])
    data["bindings"] = [b for b in data["bindings"] if b["members"]]

    print(f"  ↳ Removing {removed} ghost member(s)")
    if removed == 0:
        return 0

    tmp = "/tmp/_clean_iam_policy.json"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)

    subprocess.run(
        ["gcloud", "projects", "set-iam-policy", project, tmp, "--format=none"],
        check=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
