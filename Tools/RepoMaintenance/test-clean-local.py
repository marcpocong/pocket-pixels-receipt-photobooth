#!/usr/bin/env python3
"""Exercise cleanup deletion guards in disposable Git repositories."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pocketpixels-cleanup-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.script = self.root / "Tools/RepoMaintenance/clean-local.py"
        self.script.parent.mkdir(parents=True)
        shutil.copyfile(Path(__file__).with_name("clean-local.py"), self.script)
        self.write(".gitignore", "/DerivedData/\n/build/\n/TestResults/\n/.tmp/\n/BuildArtifacts/**\nnode_modules/\n.wrangler/\n")
        self.write("README.md", "Keep source and new work.\n")
        self.write("BuildArtifacts/reviewed.png", "tracked evidence")
        subprocess.run(["git", "-C", str(self.root), "add", "-f", ".gitignore", "README.md", "BuildArtifacts/reviewed.png"], check=True)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def run_cleanup(self, *args):
        return subprocess.run(["python3", str(self.script), *args], capture_output=True, text=True)

    def test_preview_then_apply_preserves_source_curated_evidence_and_new_work(self):
        cache = self.write("DerivedData/cache.bin", "disposable")
        raw = self.write("BuildArtifacts/raw.log", "disposable")
        new_work = self.write("Backend/PaymentsWorker/migrations/new.sql", "new work")
        self.assertEqual(self.run_cleanup().returncode, 0)
        self.assertTrue(cache.exists())
        self.assertTrue(raw.exists())
        result = self.run_cleanup("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(cache.exists())
        self.assertFalse(raw.exists())
        self.assertTrue((self.root / "README.md").exists())
        self.assertTrue((self.root / "BuildArtifacts/reviewed.png").exists())
        self.assertTrue(new_work.exists())

    def test_tracked_file_in_output_directory_aborts_before_any_deletion(self):
        tracked = self.write("DerivedData/important.txt", "keep")
        raw = self.write("BuildArtifacts/raw.log", "keep on failed preflight")
        subprocess.run(["git", "-C", str(self.root), "add", "-f", str(tracked)], check=True)
        result = self.run_cleanup("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing tracked or non-ignored file", result.stderr)
        self.assertTrue(tracked.exists())
        self.assertTrue(raw.exists())

    def test_nonignored_file_in_output_directory_aborts(self):
        self.write(".gitignore", "/BuildArtifacts/**\n")
        new_work = self.write("DerivedData/notes.txt", "keep")
        raw = self.write("BuildArtifacts/raw.log", "keep on failed preflight")
        result = self.run_cleanup("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(new_work.exists())
        self.assertTrue(raw.exists())

    def test_symlink_output_root_cannot_delete_outside_repository(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        sentinel = outside / "keep.txt"
        sentinel.write_text("keep")
        (self.root / "DerivedData").symlink_to(outside, target_is_directory=True)
        result = self.run_cleanup("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing symlink", result.stderr)
        self.assertTrue(sentinel.exists())

    def test_dependencies_require_explicit_option_and_local_database_is_preserved(self):
        dependency = self.write("Backend/PaymentsWorker/node_modules/tool/index.js", "tool")
        state = self.write("Backend/PaymentsWorker/.wrangler/state/v3/d1/local.sqlite", "local data")
        self.assertEqual(self.run_cleanup("--apply").returncode, 0)
        self.assertTrue(dependency.exists())
        result = self.run_cleanup("--apply", "--dependencies")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(dependency.exists())
        self.assertTrue(state.exists())


if __name__ == "__main__":
    unittest.main()
