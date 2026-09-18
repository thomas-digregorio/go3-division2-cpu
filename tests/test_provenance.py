"""Small synthetic file inventories only; no solver or competition-case I/O."""

from pathlib import Path
import tempfile
import unittest

from go3cpu.provenance import assert_tested_sources_unchanged, source_hashes


class TestedSourceInventory(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("Project.toml", "Manifest.toml", "manifests/sources.json",
                     "src/worker.jl", "go3cpu/checker.py"):
            self.write(name, "original")
        self.before = source_hashes(self.root)

    def write(self, name, contents):
        file = self.root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(contents, encoding="utf-8")

    def test_identical_inventory_passes(self):
        assert_tested_sources_unchanged(self.root, self.before)

    def test_new_module_requires_new_tests(self):
        self.write("src/new_algorithm.jl", "new")
        with self.assertRaisesRegex(RuntimeError, "added=.*new_algorithm"):
            assert_tested_sources_unchanged(self.root, self.before)

    def test_removed_module_requires_new_tests(self):
        (self.root / "src/worker.jl").unlink()
        with self.assertRaisesRegex(RuntimeError, "removed=.*worker"):
            assert_tested_sources_unchanged(self.root, self.before)

    def test_renamed_module_requires_new_tests(self):
        (self.root / "src/worker.jl").rename(self.root / "src/renamed.jl")
        with self.assertRaisesRegex(RuntimeError, "added=.*renamed.*removed=.*worker"):
            assert_tested_sources_unchanged(self.root, self.before)

    def test_changed_module_requires_new_tests(self):
        self.write("go3cpu/checker.py", "modified")
        with self.assertRaisesRegex(RuntimeError, "modified=.*checker"):
            assert_tested_sources_unchanged(self.root, self.before)

    def test_upstream_pin_change_requires_new_tests(self):
        self.write("manifests/sources.json", "changed-upstream")
        with self.assertRaisesRegex(RuntimeError, "modified=.*sources.json"):
            assert_tested_sources_unchanged(self.root, self.before)

    def test_new_configuration_requires_new_tests(self):
        self.write("config/new_attempt.json", "new")
        with self.assertRaisesRegex(RuntimeError, "added=.*new_attempt"):
            assert_tested_sources_unchanged(self.root, self.before)

    def test_outputs_and_documentation_do_not_change_numerical_snapshot(self):
        for name in ("runs/result.json", "tmp/scratch.json", ".cache/data.json",
                     "docs/report.md", "manifests/component_tests.json"):
            self.write(name, "generated or documentation")
        assert_tested_sources_unchanged(self.root, self.before)


if __name__ == "__main__":
    unittest.main()
