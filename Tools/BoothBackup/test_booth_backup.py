import tempfile
import unittest
from pathlib import Path

from booth_backup import restore, seal, verify


class BoothBackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.backup = self.root / "backup"
        self.container = self.backup / "container"
        for folder in ("Application Support", "Preferences"):
            (self.container / "Library" / folder).mkdir(parents=True)
        self.journal = self.container / "Library/Application Support/pending.json"
        self.journal.write_bytes(b'{"synthetic": true}')

    def test_restore_is_byte_exact_and_requires_a_new_inert_location(self):
        expected = seal(self.backup)
        target = self.root / "review"
        self.assertEqual(restore(self.backup, target), expected)
        self.assertTrue((target / "OFFLINE_REVIEW_ONLY").is_file())
        self.assertEqual(
            (target / "container" / self.journal.relative_to(self.container)).read_bytes(),
            self.journal.read_bytes(),
        )
        with self.assertRaises(FileExistsError):
            restore(self.backup, target)

    def test_mutation_and_added_files_fail_integrity_check(self):
        seal(self.backup)
        original = self.journal.read_bytes()
        self.journal.write_bytes(b"changed")
        with self.assertRaises(ValueError):
            verify(self.backup)
        self.journal.write_bytes(original)
        (self.journal.parent / "extra").touch()
        with self.assertRaises(ValueError):
            verify(self.backup)

    def test_symlinks_and_cache_are_rejected(self):
        link = self.journal.parent / "linked"
        link.symlink_to(self.journal)
        with self.assertRaises(ValueError):
            seal(self.backup)
        link.unlink()
        (self.container / "Library/Caches").mkdir()
        with self.assertRaises(ValueError):
            seal(self.backup)


if __name__ == "__main__":
    unittest.main()
