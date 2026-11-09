#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REVISION = "a" * 40
ARCHIVE_BYTES = b"synthetic Flutter SDK archive"
ARCHIVE_SHA256 = hashlib.sha256(ARCHIVE_BYTES).hexdigest()

CURL_STUB = r'''#!/usr/bin/env python3
import json
import os
import pathlib
import sys

args = sys.argv[1:]
output_path = pathlib.Path(args[args.index("--output") + 1])
url = args[-1]
with pathlib.Path(os.environ["CURL_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps({"args": args, "url": url}) + "\n")

mode = os.environ["CURL_MODE"]
if mode == "verify":
    output_path.write_bytes(pathlib.Path(os.environ["MANIFEST_FIXTURE"]).read_bytes())
elif mode == "acquire":
    if url.endswith(".intoto.jsonl") and os.environ["ATTESTATION_MODE"] == "missing":
        raise SystemExit(22)
    fixture = "ATTESTATION_FIXTURE" if url.endswith(".intoto.jsonl") else "ARCHIVE_FIXTURE"
    output_path.write_bytes(pathlib.Path(os.environ[fixture]).read_bytes())
else:
    raise SystemExit(f"unexpected curl mode: {mode}")
'''


def executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


class ReleaseScriptContractTest(unittest.TestCase):
    def setUp(self):
        self._temporary_directory = tempfile.TemporaryDirectory(prefix="release-script-contracts-")
        self.addCleanup(self._temporary_directory.cleanup)
        self.temp_dir = Path(self._temporary_directory.name)
        self.bin_dir = self.temp_dir / "bin"
        self.bin_dir.mkdir()
        executable(self.bin_dir / "curl", CURL_STUB)
        self.curl_log = self.temp_dir / "curl.jsonl"

    def environment(self, **values):
        return {
            **os.environ,
            "PATH": f"{self.bin_dir}{os.pathsep}{os.environ['PATH']}",
            "CURL_LOG": str(self.curl_log),
            **{key: str(value) for key, value in values.items()},
        }

    @staticmethod
    def release(architecture: str = "x64", revision: str = REVISION, sha256: str = ARCHIVE_SHA256):
        return {
            "version": "1.2.3",
            "channel": "stable",
            "dart_sdk_arch": architecture,
            "archive": "stable/linux/flutter_linux_1.2.3-stable.tar.xz",
            "hash": revision,
            "sha256": sha256,
        }

    def run_verifier(self, directory: Path, release: dict[str, str], expected_revision=REVISION):
        manifest = directory / "releases.json"
        manifest.write_text(json.dumps({"releases": [release]}), encoding="utf-8")
        archive = directory / "flutter-sdk.tar.xz"
        archive.write_bytes(ARCHIVE_BYTES)
        github_output = directory / "github-output.txt"
        github_output.write_text("", encoding="utf-8")
        result = subprocess.run(
            [
                str(ROOT / "scripts/verify-release.sh"),
                "1.2.3",
                "stable",
                expected_revision,
                ARCHIVE_SHA256,
                str(archive),
                str(directory / "verified.txt"),
            ],
            capture_output=True,
            text=True,
            env=self.environment(
                CURL_MODE="verify",
                MANIFEST_FIXTURE=manifest,
                GITHUB_OUTPUT=github_output,
            ),
        )
        return result, github_output, directory / "verified.txt"

    def test_release_verification_accepts_the_manifested_x64_archive(self):
        directory = self.temp_dir / "verify-valid"
        directory.mkdir()
        result, github_output, output_file = self.run_verifier(directory, self.release())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), ARCHIVE_SHA256)
        self.assertEqual(output_file.read_text(encoding="utf-8").strip(), f"archive_sha256={ARCHIVE_SHA256}")
        self.assertEqual(github_output.read_text(encoding="utf-8").strip(), f"archive_sha256={ARCHIVE_SHA256}")
        self.assertEqual(len(self.curl_log.read_text(encoding="utf-8").splitlines()), 1)

    def test_release_verification_rejects_other_architectures_and_provenance_mismatches(self):
        cases = (
            (self.release(architecture="arm64"), REVISION, "matching release"),
            (self.release(), "b" * 40, "revision differs"),
            (self.release(sha256="f" * 64), REVISION, "SHA256 differs"),
        )
        for index, (release, revision, error) in enumerate(cases):
            with self.subTest(error=error):
                directory = self.temp_dir / f"verify-invalid-{index}"
                directory.mkdir()
                result, github_output, output_file = self.run_verifier(directory, release, revision)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertEqual(github_output.read_text(encoding="utf-8"), "")
                self.assertFalse(output_file.exists())

    def run_acquirer(self, output_dir: Path, attestation_mode: str, archive_bytes=ARCHIVE_BYTES):
        archive_fixture = self.temp_dir / f"archive-{attestation_mode}-{len(archive_bytes)}.bin"
        archive_fixture.write_bytes(archive_bytes)
        attestation_fixture = self.temp_dir / "attestation.jsonl"
        attestation_fixture.write_bytes(b'{"statement":"synthetic"}\n')
        return subprocess.run(
            [str(ROOT / "scripts/acquire-flutter.sh"), "1.2.3", "stable", str(output_dir)],
            capture_output=True,
            text=True,
            env=self.environment(
                CURL_MODE="acquire",
                ATTESTATION_MODE=attestation_mode,
                ARCHIVE_FIXTURE=archive_fixture,
                ATTESTATION_FIXTURE=attestation_fixture,
            ),
        )

    def test_acquisition_keeps_sdk_when_optional_attestation_is_unavailable(self):
        output_dir = self.temp_dir / "acquire-without-attestation"
        result = self.run_acquirer(output_dir, "missing")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output_dir / "flutter-sdk.tar.xz").read_bytes(), ARCHIVE_BYTES)
        self.assertFalse((output_dir / "flutter-sdk.tar.xz.intoto.jsonl").exists())
        self.assertIn("optional Flutter attestation bundle unavailable", result.stderr)
        self.assertFalse(list(output_dir.glob(".flutter-acquire.*")))

    def test_acquisition_preserves_an_available_attestation_bundle(self):
        output_dir = self.temp_dir / "acquire-with-attestation"
        result = self.run_acquirer(output_dir, "available")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output_dir / "flutter-sdk.tar.xz").read_bytes(), ARCHIVE_BYTES)
        self.assertEqual(
            (output_dir / "flutter-sdk.tar.xz.intoto.jsonl").read_bytes(),
            b'{"statement":"synthetic"}\n',
        )
        self.assertNotIn("unavailable", result.stderr)
        self.assertFalse(list(output_dir.glob(".flutter-acquire.*")))

    def test_acquisition_rejects_an_empty_archive_without_publishing_staged_files(self):
        output_dir = self.temp_dir / "acquire-empty-archive"
        result = self.run_acquirer(output_dir, "missing", archive_bytes=b"")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("empty Flutter archive", result.stderr)
        self.assertFalse((output_dir / "flutter-sdk.tar.xz").exists())
        self.assertFalse((output_dir / "flutter-sdk.tar.xz.intoto.jsonl").exists())
        self.assertFalse(list(output_dir.glob(".flutter-acquire.*")))


if __name__ == "__main__":
    unittest.main()
