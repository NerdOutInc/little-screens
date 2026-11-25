import json
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest

from updater.prune_runs import prune


class RunRetentionTest(unittest.TestCase):
    def test_preview_boundaries_and_recovery(self):
        with tempfile.TemporaryDirectory() as temp:
            runtime = Path(temp)
            now = datetime(2026, 1, 10, tzinfo=timezone.utc)

            def run(day, screen="a"):
                name = f"2026-01-{day:02d}T000000Z"
                directory = runtime / "runs" / name
                target = directory / screen
                target.mkdir(parents=True)
                (target / "scene.png").write_bytes(b"a")
                result = dict(run=name, status="all_publications_verified",
                              screens=[dict(id=screen, verified=True)], uncertain_site_requests=[])
                (directory / "run-result.json").write_text(json.dumps(result))
                return target

            old = run(1)
            evidence = old / "calendar-browser-verification.json"
            evidence.write_bytes(b"evidence")
            last_good = run(2, "inactive")
            pending = run(3)
            (pending / "save_scene-request.json").write_text("{}")
            unfinished = run(4)
            (unfinished.parent / "run-result.json").unlink()
            boundary = run(7)
            recent = run(9)
            for apply in (False, True):
                self.assertEqual(prune(runtime, now, apply)[0], 1)
                self.assertEqual((old / "scene.png").exists(), not apply)
                self.assertEqual(evidence.read_bytes(), b"evidence")
                for target in (last_good, pending, unfinished, boundary, recent):
                    self.assertTrue((target / "scene.png").exists())
            self.assertEqual(prune(runtime, now, True), (0, 0))
