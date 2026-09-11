#!/usr/bin/env python3

from __future__ import annotations

import copy
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/update-supported-versions.py"
FIXTURE_DIR = ROOT / "tests/fixtures"

spec = importlib.util.spec_from_file_location("update_supported_versions", SCRIPT)
assert spec is not None and spec.loader is not None
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


def load_fixture(name: str):
    with (FIXTURE_DIR / name).open(encoding="utf-8") as handle:
        return json.load(handle)


def load_fixture_from_path(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def release(version: str, revision: str, sha256: str, architecture: str = "x64") -> dict[str, str]:
    return {
        "version": version,
        "channel": "stable",
        "dart_sdk_arch": architecture,
        "hash": revision,
        "archive": f"stable/linux/flutter_linux_{version}-stable.tar.xz",
        "sha256": sha256,
    }


def supported_entry(release_record: dict[str, str]) -> dict[str, str]:
    return {
        "version": release_record["version"],
        "channel": release_record["channel"],
        "revision": release_record["hash"],
        "archive": release_record["archive"],
        "archive_sha256": release_record["sha256"],
    }


class UpdateSupportedVersionsTest(unittest.TestCase):
    def make_case(self, releases=None):
        case_dir = Path(tempfile.mkdtemp(prefix="flutter-updater-test-"))
        self.addCleanup(shutil.rmtree, case_dir)
        shutil.copy(FIXTURE_DIR / "supported_version.json", case_dir / "supported_version.json")
        shutil.copy(FIXTURE_DIR / "README.md", case_dir / "README.md")
        if releases is None:
            releases = load_fixture("releases_linux.json")
        (case_dir / "releases_linux.json").write_text(
            json.dumps(releases, indent=2) + "\n", encoding="utf-8"
        )
        return case_dir

    def run_updater(self, case_dir: Path, mode: str):
        summary_json = case_dir / "summary.json"
        summary_markdown = case_dir / "summary.md"
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                mode,
                "--manifest",
                str(case_dir / "supported_version.json"),
                "--releases",
                str(case_dir / "releases_linux.json"),
                "--readme",
                str(case_dir / "README.md"),
                "--summary-json",
                str(summary_json),
                "--summary-markdown",
                str(summary_markdown),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        with summary_json.open(encoding="utf-8") as handle:
            summary = json.load(handle)
        return result, summary, summary_markdown.read_text(encoding="utf-8")

    @staticmethod
    def versions(case_dir: Path) -> list[str]:
        with (case_dir / "supported_version.json").open(encoding="utf-8") as handle:
            return [entry["version"] for entry in json.load(handle)["supported_versions"]]

    def test_no_upstream_changes_and_check_is_read_only(self):
        case_dir = self.make_case()
        before = {
            name: (case_dir / name).read_bytes() for name in ("supported_version.json", "README.md")
        }
        result, summary, _ = self.run_updater(case_dir, "--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(summary["status"], "unchanged")
        self.assertFalse(summary["update_needed"])
        self.assertEqual(before["supported_version.json"], (case_dir / "supported_version.json").read_bytes())
        self.assertEqual(before["README.md"], (case_dir / "README.md").read_bytes())

    def test_patch_replaces_patch_in_same_minor(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].append(
            release(
                "1.2.4",
                "7777777777777777777777777777777777777777",
                "1111111111111111111111111111111111111111111111111111111111111111",
            )
        )
        case_dir = self.make_case(releases)
        before_check = {
            name: (case_dir / name).read_bytes() for name in ("supported_version.json", "README.md")
        }
        check_result, check_summary, _ = self.run_updater(case_dir, "--check")
        self.assertEqual(check_result.returncode, 1)
        self.assertTrue(check_summary["update_needed"])
        self.assertEqual(before_check["supported_version.json"], (case_dir / "supported_version.json").read_bytes())
        self.assertEqual(before_check["README.md"], (case_dir / "README.md").read_bytes())
        result, summary, markdown = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.versions(case_dir), ["1.2.4", "1.4.2", "2.0.1"])
        self.assertEqual(summary["changes"]["patch_updates"][0]["from"]["version"], "1.2.3")
        self.assertEqual(summary["changes"]["patch_updates"][0]["to"]["version"], "1.2.4")
        self.assertIn("7777777777777777777777777777777777777777", markdown)
        self.assertIn("1111111111111111111111111111111111111111111111111111111111111111", markdown)

    def test_new_minor_fills_unused_support_slot(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].append(
            release(
                "2.1.0",
                "8888888888888888888888888888888888888888",
                "2222222222222222222222222222222222222222222222222222222222222222",
            )
        )
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.versions(case_dir), ["1.2.3", "1.4.2", "2.0.1", "2.1.0"])
        self.assertEqual([entry["version"] for entry in summary["changes"]["new_minors"]], ["2.1.0"])
        self.assertEqual(summary["changes"]["retired"], [])

    def test_unused_capacity_does_not_backfill_historical_minor(self):
        manifest = load_fixture("supported_version.json")
        new_minor = release(
            "2.1.0",
            "8888888888888888888888888888888888888888",
            "2222222222222222222222222222222222222222222222222222222222222222",
        )
        manifest["supported_versions"] = manifest["supported_versions"][1:] + [
            supported_entry(new_minor)
        ]
        releases = load_fixture("releases_linux.json")
        releases["releases"].extend(
            [
                new_minor,
                release(
                    "1.3.0",
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                ),
            ]
        )
        case_dir = self.make_case(releases)
        (case_dir / "supported_version.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )

        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        expected_versions = [entry["version"] for entry in manifest["supported_versions"]]
        self.assertEqual(self.versions(case_dir), expected_versions)
        self.assertNotIn("1.3.0", self.versions(case_dir))
        self.assertEqual(summary["changes"]["new_minors"], [])
        self.assertEqual(summary["changes"]["retired"], [])

    def test_fifth_minor_retires_oldest_using_policy(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].extend(
            [
                release(
                    "2.1.0",
                    "8888888888888888888888888888888888888888",
                    "2222222222222222222222222222222222222222222222222222222222222222",
                ),
                release(
                    "2.2.0",
                    "9999999999999999999999999999999999999999",
                    "3333333333333333333333333333333333333333333333333333333333333333",
                ),
            ]
        )
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.versions(case_dir), ["1.4.2", "2.0.1", "2.1.0", "2.2.0"])
        self.assertEqual([entry["version"] for entry in summary["changes"]["retired"]], ["1.2.3"])

    def test_manifest_input_order_is_shuffled(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"] = list(reversed(releases["releases"]))
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(summary["status"], "unchanged")
        self.assertEqual(self.versions(case_dir), ["1.2.3", "1.4.2", "2.0.1"])

    def test_beta_pre_release_and_malformed_version_are_ignored(self):
        case_dir = self.make_case()
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(summary["update_needed"])
        self.assertEqual(self.versions(case_dir), ["1.2.3", "1.4.2", "2.0.1"])

    def test_duplicate_upstream_exact_release_is_anomaly_and_does_not_write(self):
        releases = load_fixture("releases_linux.json")
        duplicate = copy.deepcopy(next(item for item in releases["releases"] if item.get("version") == "1.2.3"))
        duplicate["hash"] = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        releases["releases"].append(duplicate)
        case_dir = self.make_case(releases)
        before = {
            name: (case_dir / name).read_bytes() for name in ("supported_version.json", "README.md")
        }
        result, summary, markdown = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(summary["status"], "security_anomaly")
        self.assertEqual(summary["anomalies"][0]["kind"], "duplicate_upstream_release")
        self.assertEqual(summary["anomalies"][0]["old"]["version"], "1.2.3")
        self.assertIn("SECURITY ANOMALY", markdown)
        self.assertEqual(before["supported_version.json"], (case_dir / "supported_version.json").read_bytes())
        self.assertEqual(before["README.md"], (case_dir / "README.md").read_bytes())

    def test_historical_duplicate_outside_support_window_is_ignored(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].extend(
            [
                release(
                    "1.1.9",
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "1111111111111111111111111111111111111111111111111111111111111111",
                ),
                release(
                    "1.1.9",
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    "2222222222222222222222222222222222222222222222222222222222222222",
                ),
            ]
        )
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(summary["status"], "unchanged")
        self.assertFalse(summary["anomalies"])

    def test_duplicate_newest_patch_candidate_in_active_minor_is_anomaly(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].extend(
            [
                release(
                    "1.2.4",
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "1111111111111111111111111111111111111111111111111111111111111111",
                ),
                release(
                    "1.2.4",
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    "2222222222222222222222222222222222222222222222222222222222222222",
                ),
            ]
        )
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(summary["anomalies"][0]["kind"], "duplicate_upstream_release")
        self.assertEqual(summary["anomalies"][0]["version"], "1.2.4")
        self.assertIsNone(summary["anomalies"][0]["old"])

    def test_duplicate_candidate_in_newer_eligible_minor_is_anomaly(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].extend(
            [
                release(
                    "2.1.0",
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "1111111111111111111111111111111111111111111111111111111111111111",
                ),
                release(
                    "2.1.0",
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    "2222222222222222222222222222222222222222222222222222222222222222",
                ),
            ]
        )
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(summary["anomalies"][0]["kind"], "duplicate_upstream_release")
        self.assertEqual(summary["anomalies"][0]["version"], "2.1.0")

    def test_duplicate_old_non_selected_patch_inside_active_minor_is_ignored(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].extend(
            [
                release(
                    "1.2.2",
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "1111111111111111111111111111111111111111111111111111111111111111",
                ),
                release(
                    "1.2.2",
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    "2222222222222222222222222222222222222222222222222222222222222222",
                ),
            ]
        )
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(summary["status"], "unchanged")
        self.assertFalse(summary["anomalies"])

    def test_same_version_x64_and_arm64_is_not_a_duplicate(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].append(
            release(
                "1.2.3",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                "arm64",
            )
        )
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(summary["status"], "unchanged")
        self.assertEqual(self.versions(case_dir), ["1.2.3", "1.4.2", "2.0.1"])

    def test_arm64_only_unrelated_release_is_ignored(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].append(
            release(
                "3.0.0",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                "arm64",
            )
        )
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(summary["update_needed"])
        self.assertEqual(self.versions(case_dir), ["1.2.3", "1.4.2", "2.0.1"])

    def test_newer_arm64_patch_does_not_replace_x64_patch(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].append(
            release(
                "1.2.4",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                "arm64",
            )
        )
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(summary["update_needed"])
        self.assertEqual(self.versions(case_dir), ["1.2.3", "1.4.2", "2.0.1"])

    def test_trusted_metadata_mutations_are_anomalies(self):
        cases = {
            "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "archive": "stable/linux/flutter_linux_1.2.3-renamed.tar.xz",
        }
        upstream_fields = {"hash": "revision", "sha256": "archive_sha256", "archive": "archive"}
        for field, value in cases.items():
            with self.subTest(field=field):
                releases = load_fixture("releases_linux.json")
                trusted = next(item for item in releases["releases"] if item.get("version") == "1.2.3")
                trusted[field] = value
                case_dir = self.make_case(releases)
                before_manifest = (case_dir / "supported_version.json").read_bytes()
                before_readme = (case_dir / "README.md").read_bytes()
                result, summary, _ = self.run_updater(case_dir, "--write")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(summary["status"], "security_anomaly")
                self.assertEqual(summary["anomalies"][0]["version"], "1.2.3")
                self.assertEqual(summary["anomalies"][0]["upstream"][upstream_fields[field]], value)
                self.assertIn(upstream_fields[field], summary["anomalies"][0]["changed_fields"])
                self.assertEqual(before_manifest, (case_dir / "supported_version.json").read_bytes())
                self.assertEqual(before_readme, (case_dir / "README.md").read_bytes())

    def test_existing_supported_release_disappearing_is_anomaly(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"] = [item for item in releases["releases"] if item.get("version") != "1.2.3"]
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(summary["anomalies"][0]["kind"], "supported_release_disappeared")
        self.assertEqual(summary["anomalies"][0]["old"]["version"], "1.2.3")

    def test_supported_x64_disappearance_is_anomaly_even_if_arm64_remains(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"] = [item for item in releases["releases"] if item.get("version") != "1.2.3"]
        releases["releases"].append(
            release(
                "1.2.3",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                "arm64",
            )
        )
        case_dir = self.make_case(releases)
        result, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(summary["status"], "security_anomaly")
        self.assertEqual(summary["anomalies"][0]["kind"], "supported_release_disappeared")

    def test_readme_table_exactly_follows_generated_manifest(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].append(
            release(
                "2.1.0",
                "8888888888888888888888888888888888888888",
                "2222222222222222222222222222222222222222222222222222222222222222",
            )
        )
        case_dir = self.make_case(releases)
        result, _, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = load_fixture_from_path(case_dir / "supported_version.json")
        readme = (case_dir / "README.md").read_text(encoding="utf-8")
        generated = readme.split(updater.BEGIN_MARKER, 1)[1].split(updater.END_MARKER, 1)[0]
        expected = "\n" + "\n".join(
            [
                "| Flutter | Channel | Git revision | SDK archive SHA256 |",
                "| --- | --- | --- | --- |",
                *(
                    f"| {entry['version']} | {entry['channel']} | `{entry['revision']}` | `{entry['archive_sha256']}` |"
                    for entry in manifest["supported_versions"]
                ),
            ]
        ) + "\n"
        self.assertEqual(generated, expected)

    def test_second_write_produces_no_diff(self):
        releases = load_fixture("releases_linux.json")
        releases["releases"].append(
            release(
                "1.2.4",
                "7777777777777777777777777777777777777777",
                "1111111111111111111111111111111111111111111111111111111111111111",
            )
        )
        case_dir = self.make_case(releases)
        first, _, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(first.returncode, 0, first.stderr)
        after_first = {
            name: (case_dir / name).read_bytes() for name in ("supported_version.json", "README.md")
        }
        second, summary, _ = self.run_updater(case_dir, "--write")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(summary["status"], "unchanged")
        self.assertFalse(summary["update_needed"])
        self.assertEqual(after_first["supported_version.json"], (case_dir / "supported_version.json").read_bytes())
        self.assertEqual(after_first["README.md"], (case_dir / "README.md").read_bytes())


if __name__ == "__main__":
    unittest.main()
