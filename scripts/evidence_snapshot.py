#!/usr/bin/env python3
"""Capture and compare JFrog Evidence attached to a set of subjects.

The point of the lab is to tell apart evidence the pipeline attached from
evidence the platform produced on its own. A single listing cannot do that, so
this captures the same subjects at several points in the pipeline and diffs
them.

    capture <label> <out.json> <subject-repo-path>...
    report  <out.md> <snapshot.json>...

Reads JF_URL and JF_TOKEN from the environment.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

JF_URL = (os.environ.get("JF_URL") or "").rstrip("/")
JF_TOKEN = os.environ.get("JF_TOKEN") or ""


def fetch(path):
    url = f"{JF_URL}{path}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {JF_TOKEN}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode() or "{}"), resp.status
    except urllib.error.HTTPError as e:
        return {"_error": e.read().decode()[:300]}, e.code
    except Exception as e:  # network, JSON, timeout
        return {"_error": str(e)[:300]}, 0


def records_for(subject):
    """Evidence attached to one subject, normalised to the fields that matter."""
    quoted = urllib.parse.quote(subject, safe="/")
    body, status = fetch(f"/evidence/api/v1/subject/{quoted}")
    if status != 200:
        return {"status": status, "error": body.get("_error", ""), "records": []}
    out = []
    for e in body.get("evidence") or []:
        out.append(
            {
                "predicate_type": e.get("predicateType") or e.get("predicate_type"),
                "predicate_slug": e.get("predicateSlug") or e.get("predicate_slug"),
                "category": e.get("predicateCategory") or e.get("predicate_category"),
                "provider": e.get("providerId") or e.get("provider_id"),
                "created_by": e.get("createdBy") or e.get("created_by"),
                "created_at": e.get("createdAt") or e.get("created_at"),
                "name": e.get("name"),
                "verified": e.get("verified"),
            }
        )
    return {"status": status, "error": "", "records": out}


def cmd_capture(label, out_path, subjects):
    snap = {
        "label": label,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "subjects": {s: records_for(s) for s in subjects},
    }
    with open(out_path, "w") as fh:
        json.dump(snap, fh, indent=2)

    total = sum(len(v["records"]) for v in snap["subjects"].values())
    print(f"[{label}] {total} evidence record(s) across {len(subjects)} subject(s)")
    for s, v in snap["subjects"].items():
        note = "" if v["status"] == 200 else f"  (HTTP {v['status']} {v['error']})"
        print(f"  {s}: {len(v['records'])}{note}")
        for r in v["records"]:
            print(f"      - {r['predicate_type']}  provider={r['provider']}")


def key_of(rec):
    return (rec.get("predicate_type"), rec.get("provider"), rec.get("created_at"))


def cmd_report(out_path, snapshot_paths):
    snaps = []
    for p in snapshot_paths:
        try:
            with open(p) as fh:
                snaps.append(json.load(fh))
        except FileNotFoundError:
            print(f"missing snapshot {p}, skipping", file=sys.stderr)
    if not snaps:
        return

    labels = [s["label"] for s in snaps]
    subjects = []
    for s in snaps:
        for subj in s["subjects"]:
            if subj not in subjects:
                subjects.append(subj)

    lines = ["## Evidence snapshots", ""]
    lines.append("Counts per subject at each point in the pipeline.")
    lines.append("")
    lines.append("| Subject | " + " | ".join(labels) + " |")
    lines.append("|---" * (len(labels) + 1) + "|")
    for subj in subjects:
        counts = [str(len((s["subjects"].get(subj) or {"records": []})["records"])) for s in snaps]
        lines.append(f"| `{subj}` | " + " | ".join(counts) + " |")
    lines.append("")

    # The headline result: anything present before the pipeline attached
    # anything, or appearing after promotion without a matching jf evd create,
    # came from the platform.
    first, last = snaps[0], snaps[-1]
    lines.append(f"### Records present at `{first['label']}` (before any jf evd create)")
    lines.append("")
    pre = [
        (subj, r)
        for subj in subjects
        for r in (first["subjects"].get(subj) or {"records": []})["records"]
    ]
    if pre:
        lines.append("Platform-generated, since the pipeline had not attached anything yet:")
        lines.append("")
        lines.append("| Subject | Predicate type | Category | Provider |")
        lines.append("|---|---|---|---|")
        for subj, r in pre:
            lines.append(
                f"| `{subj}` | `{r['predicate_type']}` | {r['category']} | {r['provider']} |"
            )
    else:
        lines.append(
            "**None.** Publishing a package and having it scanned did not by itself "
            "produce any evidence."
        )
    lines.append("")

    lines.append(f"### New records between `{first['label']}` and `{last['label']}`")
    lines.append("")
    lines.append("| Subject | Predicate type | Category | Provider | Attributed to |")
    lines.append("|---|---|---|---|---|")
    any_new = False
    for subj in subjects:
        before = {key_of(r) for r in (first["subjects"].get(subj) or {"records": []})["records"]}
        for r in (last["subjects"].get(subj) or {"records": []})["records"]:
            if key_of(r) in before:
                continue
            any_new = True
            origin = "this pipeline" if r.get("provider") == "xray-lab" else "platform"
            lines.append(
                f"| `{subj}` | `{r['predicate_type']}` | {r['category']} "
                f"| {r['provider']} | {origin} |"
            )
    if not any_new:
        lines.append("| _no new records_ | | | | |")
    lines.append("")

    with open(out_path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n".join(lines))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    if not JF_URL or not JF_TOKEN:
        print("JF_URL and JF_TOKEN must be set", file=sys.stderr)
        return 1
    cmd = sys.argv[1]
    if cmd == "capture" and len(sys.argv) >= 4:
        cmd_capture(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif cmd == "report" and len(sys.argv) >= 4:
        cmd_report(sys.argv[2], sys.argv[3:])
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
