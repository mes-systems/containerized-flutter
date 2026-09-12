#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/update-supported-bases.py"
BASE_MANIFEST = ROOT / "supported_bases.json"
README = ROOT / "README.md"

spec = importlib.util.spec_from_file_location("update_supported_bases", SCRIPT)
assert spec is not None and spec.loader is not None
updater = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = updater
spec.loader.exec_module(updater)


def digest(body: bytes) -> str:
    return f"sha256:{hashlib.sha256(body).hexdigest()}"


def manifest_body(media_type: str, marker: str = "a") -> bytes:
    descriptor_digest = f"sha256:{marker * 64}"
    if media_type in {
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    }:
        value = {
            "schemaVersion": 2,
            "mediaType": media_type,
            "manifests": [
                {
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "size": 123,
                    "digest": descriptor_digest,
                }
            ],
        }
    else:
        value = {
            "schemaVersion": 2,
            "mediaType": media_type,
            "config": {
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "size": 123,
                "digest": descriptor_digest,
            },
            "layers": [],
        }
    return json.dumps(value, separators=(",", ":")).encode("utf-8")


def manifest_response(
    body: bytes,
    media_type: str = "application/vnd.oci.image.index.v1+json",
    header: str | None | bool = None,
    status: int = 200,
) -> updater.HTTPResponse:
    headers = {"Content-Type": media_type}
    if header is not False:
        headers["Docker-Content-Digest"] = header or digest(body)
    return updater.HTTPResponse(status=status, headers=headers, body=body)


class QueueTransport:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls: list[tuple[str, dict[str, str], float]] = []

    def __call__(self, url, headers, timeout):
        self.calls.append((url, dict(headers), timeout))
        if not self.responses:
            raise AssertionError("unexpected HTTP request")
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


def token_response(payload: object = None, status: int = 200) -> updater.HTTPResponse:
    if payload is None:
        payload = {"token": "test-bearer-token"}
    return updater.HTTPResponse(
        status=status,
        headers={"Content-Type": "application/json"},
        body=json.dumps(payload).encode("utf-8"),
    )


def base_entry(
    base_id: str = "ubuntu24.04",
    family: str = "ubuntu",
    version: str = "24.04",
    tag: str = "24.04",
    marker: str = "1",
) -> dict[str, str]:
    return {
        "id": base_id,
        "family": family,
        "version": version,
        "variant": "default",
        "reference": f"{family}:{tag}@sha256:{marker * 64}",
    }


def base_manifest(*bases: dict[str, str]) -> dict[str, object]:
    return {"schema": 1, "bases": list(bases)}


def resolver_for(**digests: str):
    def resolve(parsed):
        return digests[parsed.tag_reference]

    return resolve


class ReferenceAndHTTPTest(unittest.TestCase):
    def test_official_image_reference_parsing(self):
        parsed = updater.parse_base_reference("ubuntu:24.04@sha256:" + "a" * 64)
        self.assertEqual(parsed.repository, "ubuntu")
        self.assertEqual(parsed.tag, "24.04")
        self.assertEqual(parsed.tag_reference, "ubuntu:24.04")
        self.assertEqual(parsed.normalized_repository, "library/ubuntu")
        self.assertEqual(parsed.digest, "sha256:" + "a" * 64)

        debian = updater.parse_base_reference("debian:13@sha256:" + "b" * 64)
        self.assertEqual(debian.normalized_repository, "library/debian")
        self.assertEqual(debian.tag, "13")

        slim = updater.parse_base_reference("debian:trixie-slim@sha256:" + "c" * 64)
        self.assertEqual(slim.tag_reference, "debian:trixie-slim")

    def test_docker_hub_library_normalization(self):
        self.assertEqual(updater.normalize_docker_hub_repository("ubuntu"), "library/ubuntu")
        self.assertEqual(updater.normalize_docker_hub_repository("debian"), "library/debian")
        self.assertEqual(updater.normalize_docker_hub_repository("library/ubuntu"), "library/ubuntu")

    def test_invalid_missing_tag_and_missing_digest_references_fail_closed(self):
        cases = (
            "not a reference",
            "ubuntu@sha256:" + "a" * 64,
            "ubuntu:24.04",
            "ubuntu:24.04@sha512:" + "a" * 128,
        )
        for reference in cases:
            with self.subTest(reference=reference):
                with self.assertRaises(updater.UpdateError):
                    updater.parse_base_reference(reference)

    def test_explicit_registry_is_unsupported(self):
        with self.assertRaisesRegex(updater.UpdateError, "unsupported registry/source"):
            updater.parse_base_reference("ghcr.io/foo/bar:tag@sha256:" + "a" * 64)
        with self.assertRaises(updater.UpdateError):
            updater.normalize_docker_hub_repository("quay.io/foo/bar")

    def test_token_endpoint_accepts_token_fields_and_request_scope(self):
        for payload in (
            {"token": "test-bearer-token"},
            {"access_token": "test-bearer-token"},
            {"token": "test-bearer-token", "access_token": "test-bearer-token"},
        ):
            with self.subTest(payload=payload):
                transport = QueueTransport(token_response(payload))
                self.assertEqual(
                    updater.request_pull_token("ubuntu", transport=transport),
                    "test-bearer-token",
                )
                self.assertIn("repository%3Alibrary%2Fubuntu%3Apull", transport.calls[0][0])

    def test_conflicting_token_fields_are_an_error_without_token_leak(self):
        with self.assertRaises(updater.UpdateError) as raised:
            updater.request_pull_token(
                "ubuntu",
                transport=QueueTransport(
                    token_response({"token": "first-secret", "access_token": "second-secret"})
                ),
            )
        self.assertNotIn("first-secret", str(raised.exception))
        self.assertNotIn("second-secret", str(raised.exception))

    def test_missing_or_malformed_token_is_an_error_without_token_leak(self):
        for payload in (
            None,
            {},
            {"token": "with whitespace"},
            {"access_token": "with whitespace"},
            {"token": None, "access_token": "valid"},
        ):
            response = (
                updater.HTTPResponse(200, {"Content-Type": "application/json"}, b"not json")
                if payload is None
                else token_response(payload)
            )
            with self.subTest(payload=payload):
                with self.assertRaises(updater.UpdateError) as raised:
                    updater.request_pull_token("ubuntu", transport=QueueTransport(response))
                self.assertNotIn("test-bearer-token", str(raised.exception))

    def test_valid_oci_and_docker_manifest_media_types(self):
        media_types = (
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
            "application/vnd.docker.distribution.manifest.v2+json",
        )
        for media_type in media_types:
            body = manifest_body(media_type)
            transport = QueueTransport(
                token_response(),
                manifest_response(body, media_type),
                manifest_response(body, media_type),
            )
            with self.subTest(media_type=media_type):
                self.assertEqual(
                    updater.resolve_tag_digest("ubuntu", "24.04", transport=transport),
                    digest(body),
                )
                self.assertEqual(len(transport.calls), 3)
                self.assertEqual(transport.calls[1][1]["Authorization"], "Bearer test-bearer-token")
                self.assertIn("application/vnd.oci.image.index.v1+json", transport.calls[1][1]["Accept"])

    def test_computed_digest_must_match_response_header(self):
        body = manifest_body("application/vnd.oci.image.index.v1+json")
        transport = QueueTransport(
            token_response(),
            manifest_response(body, header="sha256:" + "b" * 64),
        )
        with self.assertRaises(updater.SecurityAnomaly):
            updater.resolve_tag_digest("ubuntu", "24.04", transport=transport)

    def test_missing_digest_header_is_a_security_anomaly(self):
        body = manifest_body("application/vnd.oci.image.index.v1+json")
        transport = QueueTransport(token_response(), manifest_response(body, header=False))
        with self.assertRaises(updater.SecurityAnomaly):
            updater.resolve_tag_digest("ubuntu", "24.04", transport=transport)

    def test_digest_addressed_refetch_must_reproduce_digest(self):
        first = manifest_body("application/vnd.oci.image.index.v1+json", "a")
        second = manifest_body("application/vnd.oci.image.index.v1+json", "b")
        transport = QueueTransport(
            token_response(),
            manifest_response(first),
            manifest_response(second),
        )
        with self.assertRaises(updater.SecurityAnomaly):
            updater.resolve_tag_digest("ubuntu", "24.04", transport=transport)

    def test_unexpected_content_type_or_manifest_shape_is_anomaly(self):
        body = manifest_body("application/vnd.oci.image.index.v1+json")
        cases = (
            manifest_response(body, media_type="text/plain"),
            manifest_response(b"{}"),
        )
        for response in cases:
            with self.subTest(response=response):
                with self.assertRaises(updater.SecurityAnomaly):
                    updater.resolve_tag_digest(
                        "ubuntu",
                        "24.04",
                        transport=QueueTransport(token_response(), response),
                    )

    def test_http_statuses_and_network_failures_are_classified(self):
        for status in (401, 403, 429, 500, 502):
            with self.subTest(status=status):
                with self.assertRaises(updater.UpdateError):
                    updater.resolve_tag_digest(
                        "ubuntu",
                        "24.04",
                        transport=QueueTransport(token_response(status=status)),
                    )

        with self.assertRaises(updater.SecurityAnomaly):
            updater.resolve_tag_digest(
                "ubuntu",
                "24.04",
                transport=QueueTransport(token_response(), updater.HTTPResponse(404, {}, b"")),
            )
        with self.assertRaises(updater.SecurityAnomaly):
            updater.resolve_tag_digest(
                "ubuntu",
                "24.04",
                transport=QueueTransport(
                    token_response(),
                    manifest_response(manifest_body("application/vnd.oci.image.index.v1+json")),
                    updater.HTTPResponse(404, {}, b""),
                ),
            )
        with self.assertRaises(updater.UpdateError) as raised:
            updater.resolve_tag_digest(
                "ubuntu",
                "24.04",
                transport=QueueTransport(token_response(), TimeoutError("secret network detail")),
            )
        self.assertNotIn("secret network detail", str(raised.exception))


class UpdateCalculationTest(unittest.TestCase):
    def setUp(self):
        self.old_ubuntu = base_entry(marker="1")
        self.old_debian = base_entry(
            base_id="debian13", family="debian", version="13", tag="13", marker="2"
        )
        self.ubuntu_new = "sha256:" + "a" * 64
        self.debian_new = "sha256:" + "b" * 64

    def test_same_digest_is_unchanged(self):
        summary = updater.calculate_updates(
            base_manifest(self.old_ubuntu),
            resolver=resolver_for(**{"ubuntu:24.04": self.old_ubuntu["reference"].split("@", 1)[1]}),
        )
        self.assertEqual(summary["status"], "unchanged")
        self.assertFalse(summary["update_needed"])
        self.assertEqual(summary["changes"], [])

    def test_one_changed_base_changes_only_its_reference(self):
        manifest = base_manifest(self.old_ubuntu, self.old_debian)
        summary = updater.calculate_updates(
            manifest,
            resolver=resolver_for(**{"ubuntu:24.04": self.ubuntu_new, "debian:13": self.old_debian["reference"].split("@", 1)[1]}),
        )
        self.assertEqual(summary["status"], "update")
        self.assertEqual(summary["changes"], [{
            "base_id": "ubuntu24.04",
            "tag_reference": "ubuntu:24.04",
            "old_digest": "sha256:" + "1" * 64,
            "new_digest": self.ubuntu_new,
        }])

    def test_two_unchanged_bases_need_no_update(self):
        manifest = base_manifest(self.old_ubuntu, self.old_debian)
        summary = updater.calculate_updates(
            manifest,
            resolver=resolver_for(
                **{
                    "ubuntu:24.04": self.old_ubuntu["reference"].split("@", 1)[1],
                    "debian:13": self.old_debian["reference"].split("@", 1)[1],
                }
            ),
        )
        self.assertEqual(summary["status"], "unchanged")
        self.assertFalse(summary["update_needed"])
        self.assertEqual(summary["changes"], [])

    def test_two_changed_bases_are_both_reported_in_manifest_order(self):
        manifest = base_manifest(self.old_ubuntu, self.old_debian)
        summary = updater.calculate_updates(
            manifest,
            resolver=resolver_for(**{"ubuntu:24.04": self.ubuntu_new, "debian:13": self.debian_new}),
        )
        self.assertEqual([change["base_id"] for change in summary["changes"]], ["ubuntu24.04", "debian13"])

    def test_error_and_security_anomaly_do_not_produce_updates(self):
        manifest = base_manifest(self.old_ubuntu, self.old_debian)

        def error_resolver(parsed):
            if parsed.repository == "ubuntu":
                raise updater.UpdateError("network error")
            raise updater.SecurityAnomaly("digest mismatch")

        summary = updater.calculate_updates(manifest, resolver=error_resolver)
        self.assertEqual(summary["status"], "security_anomaly")
        self.assertFalse(summary["update_needed"])
        self.assertEqual(summary["changes"], [])
        self.assertEqual(len(summary["errors"]), 1)
        self.assertEqual(len(summary["anomalies"]), 1)

    def test_invalid_local_manifest_is_rejected(self):
        with self.assertRaises(updater.UpdateError):
            updater.calculate_updates({"schema": 2, "bases": []})

    def test_write_changes_only_digest_and_preserves_json_shape_and_order(self):
        case_dir = Path(tempfile.mkdtemp(prefix="base-updater-test-"))
        self.addCleanup(shutil.rmtree, case_dir)
        manifest_text = json.dumps(base_manifest(self.old_ubuntu, self.old_debian), indent=4) + "\n"
        manifest_path = case_dir / "supported_bases.json"
        readme_path = case_dir / "README.md"
        manifest_path.write_text(manifest_text, encoding="utf-8")
        prefix = "before\n\n"
        suffix = "\n\nafter\n"
        readme_path.write_text(prefix + updater.render_supported_bases(base_manifest(self.old_ubuntu, self.old_debian)) + suffix, encoding="utf-8")
        args = SimpleNamespace(manifest=str(manifest_path), readme=str(readme_path), write=True, check=False)

        summary, _ = updater.run(
            args,
            resolver=resolver_for(**{"ubuntu:24.04": self.ubuntu_new, "debian:13": self.debian_new}),
        )
        self.assertEqual(summary["status"], "update")
        updated_text = manifest_path.read_text(encoding="utf-8")
        self.assertEqual(updated_text.count('"reference"'), 2)
        self.assertEqual(json.loads(updated_text)["bases"][0]["id"], "ubuntu24.04")
        self.assertEqual(json.loads(updated_text)["bases"][1]["id"], "debian13")
        self.assertEqual(json.loads(updated_text)["bases"][0]["version"], "24.04")
        self.assertEqual(json.loads(updated_text)["bases"][0]["variant"], "default")
        self.assertEqual(json.loads(updated_text)["bases"][1]["family"], "debian")
        self.assertIn('        "id": "ubuntu24.04"', updated_text)
        self.assertIn('    "family": "debian"', updated_text)
        updated_readme = readme_path.read_text(encoding="utf-8")
        self.assertTrue(updated_readme.startswith(prefix))
        self.assertTrue(updated_readme.endswith(suffix))
        self.assertIn("`debian13`", updated_readme)

    def test_same_digest_run_is_read_only(self):
        case_dir = Path(tempfile.mkdtemp(prefix="base-updater-test-"))
        self.addCleanup(shutil.rmtree, case_dir)
        manifest_text = json.dumps(base_manifest(self.old_ubuntu), indent=2) + "\n"
        manifest_path = case_dir / "supported_bases.json"
        readme_path = case_dir / "README.md"
        manifest_path.write_text(manifest_text, encoding="utf-8")
        readme_path.write_text(updater.render_supported_bases(base_manifest(self.old_ubuntu)), encoding="utf-8")
        before = (manifest_path.read_bytes(), readme_path.read_bytes())
        args = SimpleNamespace(manifest=str(manifest_path), readme=str(readme_path), write=True, check=False)
        summary, _ = updater.run(
            args,
            resolver=resolver_for(**{"ubuntu:24.04": self.old_ubuntu["reference"].split("@", 1)[1]}),
        )
        self.assertEqual(summary["status"], "unchanged")
        self.assertEqual(before, (manifest_path.read_bytes(), readme_path.read_bytes()))

    def test_update_without_write_is_read_only(self):
        case_dir = Path(tempfile.mkdtemp(prefix="base-updater-test-"))
        self.addCleanup(shutil.rmtree, case_dir)
        manifest_text = json.dumps(base_manifest(self.old_ubuntu), indent=2) + "\n"
        manifest_path = case_dir / "supported_bases.json"
        readme_path = case_dir / "README.md"
        manifest_path.write_text(manifest_text, encoding="utf-8")
        readme_path.write_text(updater.render_supported_bases(base_manifest(self.old_ubuntu)), encoding="utf-8")
        before = (manifest_path.read_bytes(), readme_path.read_bytes())
        args = SimpleNamespace(manifest=str(manifest_path), readme=str(readme_path), write=False, check=False)
        summary, _ = updater.run(
            args,
            resolver=resolver_for(**{"ubuntu:24.04": "sha256:" + "f" * 64}),
        )
        self.assertEqual(summary["status"], "update")
        self.assertEqual(before, (manifest_path.read_bytes(), readme_path.read_bytes()))


class ReadmeAndSummaryTest(unittest.TestCase):
    def setUp(self):
        self.ubuntu = base_entry(marker="1")
        self.debian = base_entry(
            base_id="debian13", family="debian", version="13", tag="13", marker="2"
        )

    def test_repository_readme_block_matches_current_manifest(self):
        manifest = json.loads(BASE_MANIFEST.read_text(encoding="utf-8"))
        readme = README.read_text(encoding="utf-8")
        self.assertEqual(updater.render_readme(readme, manifest), readme)

    def test_generated_markers_and_table_render_exactly_once(self):
        block = updater.render_supported_bases([self.ubuntu])
        self.assertEqual(block.count(updater.BEGIN_MARKER), 1)
        self.assertEqual(block.count(updater.END_MARKER), 1)
        readme = "prefix\n" + block + "\nsuffix"
        rendered = updater.render_readme(readme, [self.ubuntu])
        self.assertEqual(rendered.count(updater.BEGIN_MARKER), 1)
        self.assertEqual(rendered.count(updater.END_MARKER), 1)

    def test_new_and_removed_synthetic_bases_and_short_digest_render(self):
        one = updater.render_supported_bases([self.ubuntu])
        two = updater.render_supported_bases([self.ubuntu, self.debian])
        self.assertNotIn("debian13", one)
        self.assertIn("`debian13`", two)
        self.assertIn("`sha256:" + "1" * 12 + "...`", one)
        changed = dict(self.ubuntu, reference="ubuntu:24.04@sha256:" + "f" * 64)
        self.assertIn("`sha256:" + "f" * 12 + "...`", updater.render_supported_bases([changed]))

    def test_text_outside_generated_markers_is_byte_for_byte_unchanged(self):
        prefix = "prefix\r\n\n"
        suffix = "\r\n\nsuffix\r\n"
        readme = prefix + updater.render_supported_bases([self.ubuntu]) + suffix
        rendered = updater.render_readme(readme, [self.debian])
        self.assertTrue(rendered.startswith(prefix))
        self.assertTrue(rendered.endswith(suffix))

    def test_missing_duplicate_and_reversed_markers_fail(self):
        block = updater.render_supported_bases([self.ubuntu])
        cases = (
            "no markers",
            block + "\n" + block,
            updater.END_MARKER + "\n" + updater.BEGIN_MARKER,
        )
        for readme in cases:
            with self.subTest(readme=readme):
                with self.assertRaises(updater.UpdateError):
                    updater.render_readme(readme, [self.ubuntu])

    def test_summary_json_and_markdown_cover_all_states_without_credentials(self):
        unchanged = updater.calculate_updates(
            base_manifest(self.ubuntu),
            resolver=resolver_for(**{"ubuntu:24.04": self.ubuntu["reference"].split("@", 1)[1]}),
        )
        update = updater.calculate_updates(
            base_manifest(self.ubuntu),
            resolver=resolver_for(**{"ubuntu:24.04": "sha256:" + "f" * 64}),
        )
        error = updater.calculate_updates(
            base_manifest(self.ubuntu),
            resolver=lambda parsed: (_ for _ in ()).throw(updater.UpdateError("Docker Hub 429")),
        )
        anomaly = updater.calculate_updates(
            base_manifest(self.ubuntu),
            resolver=lambda parsed: (_ for _ in ()).throw(updater.SecurityAnomaly("digest mismatch")),
        )
        for summary, heading, expected_status in (
            (unchanged, "Base image watcher", "unchanged"),
            (update, "Base image updates", "update"),
            (error, "Base image watcher: ERROR", "error"),
            (anomaly, "Base image watcher: SECURITY ANOMALY", "security_anomaly"),
        ):
            with self.subTest(status=expected_status):
                json.dumps({key: value for key, value in summary.items() if not key.startswith("_")})
                markdown = updater.render_summary_markdown(summary)
                self.assertIn(heading, markdown)
                self.assertNotIn("Bearer", markdown)
                self.assertNotIn("test-bearer-token", markdown)


if __name__ == "__main__":
    unittest.main()
