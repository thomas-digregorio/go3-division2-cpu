"""Bounded source retrieval using mocks only; never download or solve a case."""
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from scripts.audit_sources import NETWORKS, RAW_CASE_CAP_BYTES, extract_case

ROOT = Path(__file__).resolve().parents[1]


class SourceDownloadTests(unittest.TestCase):
    def test_only_audited_networks_have_larger_raw_cap(self):
        self.assertEqual(set(RAW_CASE_CAP_BYTES), set(NETWORKS))
        for network in NETWORKS:
            self.assertEqual(RAW_CASE_CAP_BYTES[network],
                             (256 if network == "C3E4N23643D2" else
                              128 if network in ("C3E4N06717D2", "C3E4N08316D2") else 64) * 1024**2)
        self.assertLess(236_784_393, RAW_CASE_CAP_BYTES["C3E4N23643D2"])

    def test_oversized_member_rejected_before_read_or_output(self):
        for network in ("C3E4N06049D2", "C3E4N06717D2", "C3E4N08316D2", "C3E4N23643D2"):
            with self.subTest(network=network), tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
                destination = Path(d)/"raw.json"
                with patch("scripts.audit_sources.storage_check") as storage, \
                     patch("scripts.audit_sources.RemoteZip") as remote, \
                     patch("scripts.audit_sources.zipfile.ZipFile") as zipped:
                    archive = zipped.return_value.__enter__.return_value
                    archive.getinfo.return_value = SimpleNamespace(
                        file_size=RAW_CASE_CAP_BYTES[network]+1)
                    with self.assertRaisesRegex(RuntimeError, "registered download cap"):
                        extract_case(f"D2/{network}/scenario_002.json", destination, network)
                    storage.assert_called_once_with(destination, pending_bytes=RAW_CASE_CAP_BYTES[network])
                    # No transfer-budget override is passed to the bounded reader.
                    self.assertEqual(len(remote.call_args.args), 1)
                    self.assertEqual(remote.call_args.kwargs, {})
                    archive.read.assert_not_called()
                    self.assertFalse(destination.exists())

    def test_23643_audited_member_uses_existing_bounded_transfer(self):
        # Tiny mocked payload: test the declared member-size admission without
        # downloading data or allocating the actual 237 MB member in a test.
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d:
            destination = Path(d)/"raw.json"
            with patch("scripts.audit_sources.storage_check") as storage, \
                 patch("scripts.audit_sources.RemoteZip") as remote, \
                 patch("scripts.audit_sources.zipfile.ZipFile") as zipped:
                remote.return_value.max_transfer = 16 * 1024**2
                remote.return_value.transferred = 2
                remote.return_value.etag = '"fixture"'
                archive = zipped.return_value.__enter__.return_value
                archive.getinfo.return_value = SimpleNamespace(file_size=236_784_393)
                archive.read.return_value = b"{}"
                report = extract_case("D2/C3E4N23643D2/scenario_003.json", destination,
                                      "C3E4N23643D2")
                storage.assert_called_once_with(destination, pending_bytes=256 * 1024**2)
                remote.assert_called_once_with(
                    "https://data.openei.org/files/5997/C3E4N23643_20231002.zip")
                self.assertEqual(report["transfer_cap_bytes"], 16 * 1024**2)
                self.assertEqual(report["raw_cap_bytes"], 256 * 1024**2)
                self.assertEqual(destination.read_bytes(), b"{}")

    def test_pop_other_network_and_existing_output_rejected_without_network(self):
        with tempfile.TemporaryDirectory(dir=ROOT/"tmp") as d, \
             patch("scripts.audit_sources.RemoteZip") as remote:
            destination = Path(d)/"raw.json"
            for entry in ("D2/C3E4N06717D2/pop_solution_002.json",
                          "D2/C3E4N06049D2/scenario_002.json"):
                with self.assertRaises(ValueError):
                    extract_case(entry, destination, "C3E4N06717D2")
            with self.assertRaises(FileExistsError):
                extract_case("D2/C3E4N06717D2/scenario_002.json", Path(d), "C3E4N06717D2")
            remote.assert_not_called()


if __name__ == "__main__":
    unittest.main()
