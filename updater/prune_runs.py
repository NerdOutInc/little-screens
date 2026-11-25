"""Prune completed TRMNL refresh artifacts. Preview unless --apply is given."""
import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re

RUN_NAME = re.compile(r"(\d{4}-\d\d-\d\dT\d{6}Z)(?:-[\w-]+)?")
REQUEST_NAMES = {a + "-request.json" for a in ("save_screen", "save_scene", "publish_screen")}


def record(path):
    if path.is_symlink():
        return {}
    try:
        data = json.loads(path.read_bytes())
    except (FileNotFoundError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def verified_ids(result):
    screens = result.get("screens")
    if not isinstance(screens, list):
        return set()
    return {s["id"] for s in screens if isinstance(s, dict)
            and isinstance(s.get("id"), str) and s.get("verified") is True}


def completed(run, result):
    ids = verified_ids(result)
    return (result.get("run") == run.name
            and result.get("status") == "all_publications_verified"
            and result.get("uncertain_site_requests") == []
            and bool(ids) and len(ids) == len(result["screens"]))


def settled(request_file):
    action = request_file.name.removesuffix("-request.json")
    request = record(request_file)
    receipt = record(request_file.with_name(action + "-receipt.json"))
    return (bool(request.get("request_id"))
            and request.get("id") == request_file.parent.name == receipt.get("id")
            and type(request.get("expected_revision")) is int
            and receipt.get("committed") is True
            and receipt.get("revision") == request["expected_revision"] + 1)


def calendar_evidence(path):
    name = path.name.lower()
    return (("calendar" in name and any(k in name for k in ("verif", "evidence", "resolution")))
            or "confirm" in name or "all-day" in name or "all_day" in name)


def prune(runtime, now, apply=False):
    root = runtime / "runs"
    if runtime.is_symlink() or root.is_symlink():
        raise ValueError("Expected a local runtime and runs directory")
    candidates = []
    newest = {}
    for run in sorted(root.glob("*")):
        match = RUN_NAME.fullmatch(run.name)
        if not match or run.is_symlink() or not run.is_dir():
            continue
        try:
            timestamp = datetime.strptime(match[1], "%Y-%m-%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        result = record(run / "run-result.json")
        ids = verified_ids(result)
        for file in run.glob("*/verified-result.json"):
            if not file.parent.is_symlink() and record(file).get("verified") is True:
                ids.add(file.parent.name)
        for screen in ids:
            newest[screen] = run
        if timestamp < now - timedelta(days=3) and completed(run, result):
            candidates.append(run)
    protected = set(newest.values())
    summary = record(runtime / "latest-run-summary.json")
    if isinstance(summary.get("run"), str):
        protected.add(root / summary["run"])
    if summary.get("uncertain_site_requests"):
        return 0, 0
    count = total = 0
    for run in candidates:
        if run in protected:
            continue
        entries = sorted(run.rglob("*"), key=lambda p: len(p.parts), reverse=True)
        if any(p.is_symlink() for p in entries):
            continue
        requests = [p for p in entries if p.name in REQUEST_NAMES]
        if any(not settled(p) for p in requests):
            continue
        marker = run / "run-result.json"
        files = [p for p in entries if p.is_file() and p != marker and not calendar_evidence(p)]
        # Remove settled requests before receipts so an interrupted cleanup can resume.
        files.sort(key=lambda p: p.name not in REQUEST_NAMES)
        files.append(marker)
        for file in files:
            info = file.stat()
            total += info.st_blocks * 512 if hasattr(info, "st_blocks") else info.st_size
            if apply:
                file.unlink()
        if apply:
            for directory in [p for p in entries if p.is_dir()] + [run]:
                if not any(directory.iterdir()):
                    directory.rmdir()
        count += 1
    return count, total


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    runtime = Path(__file__).resolve().parents[1] / ".runtime"
    count, size = prune(runtime, datetime.now(timezone.utc), args.apply)
    print(f"{'Pruned' if args.apply else 'Would prune'} {count} runs ({size / 1e9:.3f} GB on disk)")
