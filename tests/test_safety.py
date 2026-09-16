import collections
from pathlib import Path
import unittest

from go3cpu.safety import GIB, local_path, storage_check


class SafetyTests(unittest.TestCase):
    def test_onedrive_raw_rejected(self):
        for p in ["C:/Users/u/OneDrive/data", "../ONEDRIVE/tmp", "data/OneDrive-backup"]:
            with self.assertRaises(ValueError):
                local_path(p)

    def test_local_path(self):
        self.assertTrue(local_path("tmp/fixture").is_absolute())

    def test_floor_cannot_be_lowered(self):
        with self.assertRaises(ValueError):
            storage_check(".", floor_bytes=29 * GIB)

    def test_estimated_writes_reserved(self):
        usage = collections.namedtuple("usage", "total used free")(100 * GIB, 69 * GIB, 31 * GIB)
        with self.assertRaises(RuntimeError):
            storage_check(".", pending_bytes=2 * GIB, disk_usage=lambda _: usage)
        self.assertEqual(storage_check(".", pending_bytes=GIB, disk_usage=lambda _: usage)["free_bytes"], 31 * GIB)


if __name__ == "__main__":
    unittest.main()
