#!/usr/bin/env python3
"""Derive the active Flutter support window from an official release manifest."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any


BEGIN_MARKER = "<!-- BEGIN GENERATED SUPPORTED FLUTTER RELEASES -->"
END_MARKER = "<!-- END GENERATED SUPPORTED FLUTTER RELEASES -->"
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
REVISION_RE = re.compile(r"^[0-9a-fA-F]{40}$")
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
COMMON_ENTRY_FIELDS = ("version", "channel", "revision")
ARTIFACT_FIELDS = ("upstream_arch", "archive", "archive_sha256")
PLATFORM_SPECS = {
    "linux/amd64": {
        "upstream_arch": "x64",
        "archive_template": "{channel}/linux/flutter_linux_{version}-{channel}.tar.xz",
    },
}


class UpdateError(Exception):
    """An input or output error that is not an upstream trust anomaly."""


def version_key(version: str) -> tuple[int, int, int]:
    match = VERSION_RE.fullmatch(version)
    if match is None:
        raise UpdateError(f"invalid Flutter version: {version}")
    return tuple(int(component) for component in match.groups())


def load_json(path: Path, description: str) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as error:
        raise UpdateError(f"{description} not found: {path}") from error
    except OSError as error:
        raise UpdateError(f"could not read {description} {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise UpdateError(f"invalid JSON in {description} {path}: {error}") from error


def require_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value:
        raise UpdateError(f"{name} must be a non-empty string")
    return value


def expected_archive(platform: str, version: str, channel: str) -> str:
    try:
        template = PLATFORM_SPECS[platform]["archive_template"]
    except KeyError as error:
        raise UpdateError(f"unsupported Flutter platform: {platform}") from error
    return template.format(version=version, channel=channel)


def compact_artifact(artifact: dict[str, Any]) -> dict[str, Any]:
    return {field: artifact[field] for field in ARTIFACT_FIELDS}


def compact_entry(entry: dict[str, Any]) -> dict[str, Any]:
    return {
        **{field: entry[field] for field in COMMON_ENTRY_FIELDS},
        "artifacts": {
            platform: compact_artifact(entry["artifacts"][platform])
            for platform in sorted(entry["artifacts"])
        },
    }


def raw_release_metadata(release: dict[str, Any], platform: str) -> dict[str, Any]:
    return {
        "version": release.get("version"),
        "platform": platform,
        "channel": release.get("channel"),
        "upstream_arch": release.get("dart_sdk_arch"),
        "dart_sdk_arch": release.get("dart_sdk_arch"),
        "revision": release.get("hash"),
        "archive": release.get("archive"),
        "archive_sha256": release.get("sha256"),
    }


def validate_supported_manifest(manifest: Any, path: Path) -> tuple[dict[str, Any], list[dict[str, Any]], int]:
    if not isinstance(manifest, dict):
        raise UpdateError(f"{path}: manifest must be an object")
    if type(manifest.get("schema")) is not int or manifest["schema"] != 2:
        raise UpdateError(f"{path}: schema must be 2")

    policy = manifest.get("support_policy")
    if not isinstance(policy, dict):
        raise UpdateError(f"{path}: support_policy must be an object")
    if policy.get("channel") != "stable":
        raise UpdateError(f"{path}: support_policy.channel must be stable")
    minor_lines = policy.get("minor_lines")
    if type(minor_lines) is not int or minor_lines <= 0:
        raise UpdateError(f"{path}: support_policy.minor_lines must be a positive integer")
    if policy.get("selection") != "latest_patch_per_minor":
        raise UpdateError(f"{path}: unsupported support_policy.selection")
    platforms = policy.get("platforms")
    if not isinstance(platforms, list) or not platforms:
        raise UpdateError(f"{path}: support_policy.platforms must be a non-empty array")
    if any(not isinstance(platform, str) or not platform for platform in platforms):
        raise UpdateError(f"{path}: support_policy.platforms must contain non-empty strings")
    if len(set(platforms)) != len(platforms):
        raise UpdateError(f"{path}: support_policy.platforms must contain unique platforms")
    if set(platforms) != set(PLATFORM_SPECS):
        raise UpdateError(f"{path}: unsupported support_policy.platforms: {platforms}")

    supported_versions = manifest.get("supported_versions")
    if not isinstance(supported_versions, list) or not supported_versions:
        raise UpdateError(f"{path}: supported_versions must be a non-empty array")
    if len(supported_versions) > minor_lines:
        raise UpdateError(f"{path}: supported_versions exceeds support_policy.minor_lines")

    entries: list[dict[str, Any]] = []
    seen_versions: set[str] = set()
    seen_minors: set[tuple[int, int]] = set()
    for index, candidate in enumerate(supported_versions):
        if not isinstance(candidate, dict):
            raise UpdateError(f"{path}: supported_versions[{index}] must be an object")
        if set(candidate) != {"version", "channel", "revision", "artifacts"}:
            raise UpdateError(f"{path}: invalid fields for supported_versions[{index}]")
        version = require_string(candidate.get("version"), f"{path}: version")
        parsed_version = VERSION_RE.fullmatch(version)
        if parsed_version is None:
            raise UpdateError(f"{path}: invalid version: {version}")
        numeric_version = tuple(int(component) for component in parsed_version.groups())
        minor = numeric_version[:2]
        if version in seen_versions:
            raise UpdateError(f"{path}: duplicate Flutter version: {version}")
        if minor in seen_minors:
            raise UpdateError(f"{path}: duplicate Flutter minor line: {minor[0]}.{minor[1]}")
        seen_versions.add(version)
        seen_minors.add(minor)

        channel = require_string(candidate.get("channel"), f"{path}: channel for {version}")
        if channel != policy["channel"]:
            raise UpdateError(f"{path}: unsupported channel for {version}: {channel}")
        revision = require_string(candidate.get("revision"), f"{path}: revision for {version}")
        if REVISION_RE.fullmatch(revision) is None:
            raise UpdateError(f"{path}: revision must be exactly 40 hexadecimal characters for {version}")
        artifacts = candidate.get("artifacts")
        if not isinstance(artifacts, dict):
            raise UpdateError(f"{path}: artifacts must be an object for {version}")
        if set(artifacts) != set(platforms):
            raise UpdateError(f"{path}: artifacts must contain exactly support_policy.platforms for {version}")
        for platform in platforms:
            artifact = artifacts[platform]
            if not isinstance(artifact, dict) or set(artifact) != set(ARTIFACT_FIELDS):
                raise UpdateError(f"{path}: invalid artifact for {version} on {platform}")
            upstream_arch = require_string(
                artifact.get("upstream_arch"), f"{path}: upstream_arch for {version} on {platform}"
            )
            if upstream_arch != PLATFORM_SPECS[platform]["upstream_arch"]:
                raise UpdateError(f"{path}: invalid upstream_arch for {version} on {platform}")
            archive = require_string(
                artifact.get("archive"), f"{path}: archive for {version} on {platform}"
            )
            if archive != expected_archive(platform, version, channel):
                raise UpdateError(f"{path}: archive does not match version/channel for {version} on {platform}")
            archive_sha256 = require_string(
                artifact.get("archive_sha256"), f"{path}: archive_sha256 for {version} on {platform}"
            )
            if SHA256_RE.fullmatch(archive_sha256) is None:
                raise UpdateError(
                    f"{path}: archive_sha256 must be exactly 64 hexadecimal characters for {version} on {platform}"
                )
        entries.append(compact_entry(candidate))

    return dict(policy), entries, minor_lines


def valid_release(release: Any, policy_channel: str, platform: str) -> dict[str, Any] | None:
    spec = PLATFORM_SPECS.get(platform)
    if (
        not isinstance(release, dict)
        or release.get("channel") != policy_channel
        or spec is None
        or release.get("dart_sdk_arch") != spec["upstream_arch"]
    ):
        return None
    version = release.get("version")
    if not isinstance(version, str) or VERSION_RE.fullmatch(version) is None:
        return None
    revision = release.get("hash")
    archive = release.get("archive")
    archive_sha256 = release.get("sha256")
    expected = expected_archive(platform, version, policy_channel)
    if (
        not isinstance(revision, str)
        or REVISION_RE.fullmatch(revision) is None
        or not isinstance(archive, str)
        or archive != expected
        or not isinstance(archive_sha256, str)
        or SHA256_RE.fullmatch(archive_sha256) is None
    ):
        return None
    return {
        "version": version,
        "channel": policy_channel,
        "revision": revision,
        "artifacts": {
            platform: {
                "upstream_arch": spec["upstream_arch"],
                "archive": archive,
                "archive_sha256": archive_sha256,
            }
        },
    }


def anomaly(
    kind: str,
    version: str,
    old: dict[str, Any] | None,
    upstream: Any,
    message: str,
    fields: list[str] | None = None,
    platform: str | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "kind": kind,
        "version": version,
        "message": message,
        "old": old,
        "upstream": upstream,
    }
    if platform is not None:
        result["platform"] = platform
    if fields:
        result["changed_fields"] = fields
    return result


def collect_releases(
    release_manifest: Any, policy_channel: str, platforms: list[str]
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, list[dict[str, Any]]]]]:
    if not isinstance(release_manifest, dict) or not isinstance(release_manifest.get("releases"), list):
        raise UpdateError("release manifest must be an object with a releases array")

    raw_by_version: dict[str, dict[str, list[dict[str, Any]]]] = {}
    for release in release_manifest["releases"]:
        if not isinstance(release, dict) or release.get("channel") != policy_channel:
            continue
        version = release.get("version")
        if not isinstance(version, str) or VERSION_RE.fullmatch(version) is None:
            continue
        platform = release_platform(release, platforms)
        if platform is not None:
            raw_by_version.setdefault(version, {}).setdefault(platform, []).append(release)

    candidates: dict[str, dict[str, Any]] = {}
    for version in sorted(raw_by_version, key=version_key):
        artifacts: dict[str, dict[str, Any]] = {}
        revisions: list[str] = []
        for platform in platforms:
            valid_candidates = [
                candidate
                for release in raw_by_version[version].get(platform, [])
                if (candidate := valid_release(release, policy_channel, platform)) is not None
            ]
            if not valid_candidates:
                break
            chosen = sorted(
                valid_candidates,
                key=lambda item: json.dumps(item, sort_keys=True, separators=(",", ":")),
            )[0]
            artifacts[platform] = chosen["artifacts"][platform]
            revisions.append(chosen["revision"])
        if len(artifacts) == len(platforms):
            candidates[version] = {
                "version": version,
                "channel": policy_channel,
                "revision": sorted(revisions)[0],
                "artifacts": artifacts,
            }

    return candidates, raw_by_version


def release_platform(release: dict[str, Any], platforms: list[str]) -> str | None:
    for platform in platforms:
        if release.get("dart_sdk_arch") == PLATFORM_SPECS[platform]["upstream_arch"]:
            return platform
    return None


def find_trust_anomalies(
    current_entries: list[dict[str, Any]],
    candidates: dict[str, dict[str, Any]],
    raw_by_version: dict[str, dict[str, list[dict[str, Any]]]],
    minor_lines: int,
    platforms: list[str],
    policy_channel: str,
) -> list[dict[str, Any]]:
    current_by_version = {entry["version"]: entry for entry in current_entries}
    selected_versions = {
        entry["version"] for entry in select_supported(candidates, current_entries, minor_lines, platforms)
    }
    relevant_versions = set(current_by_version) | selected_versions
    anomalies: list[dict[str, Any]] = []
    for version in sorted(relevant_versions, key=version_key):
        releases_by_platform = raw_by_version.get(version, {})
        for platform in platforms:
            releases = releases_by_platform.get(platform, [])
            if len(releases) > 1:
                upstream_metadata = sorted(
                    (raw_release_metadata(release, platform) for release in releases),
                    key=lambda item: json.dumps(item, sort_keys=True, separators=(",", ":")),
                )
                anomalies.append(
                    anomaly(
                        "duplicate_upstream_release",
                        version,
                        current_by_version.get(version),
                        upstream_metadata,
                        f"official manifest contains {len(releases)} {platform} entries for {version}",
                        platform=platform,
                    )
                )

        valid_revisions: dict[str, str] = {}
        for platform in platforms:
            releases = releases_by_platform.get(platform, [])
            if len(releases) == 1:
                candidate = valid_release(releases[0], policy_channel, platform)
                if candidate is not None:
                    valid_revisions[platform] = candidate["revision"]
        if len(set(valid_revisions.values())) > 1:
            upstream_metadata = [
                raw_release_metadata(releases_by_platform[platform][0], platform)
                for platform in platforms
                if platform in valid_revisions
            ]
            for platform in valid_revisions:
                anomalies.append(
                    anomaly(
                        "upstream_revision_mismatch",
                        version,
                        current_by_version.get(version),
                        upstream_metadata,
                        f"required platform artifacts for {version} have different Flutter revisions",
                        ["revision"],
                        platform=platform,
                    )
                )
    for current in current_entries:
        version = current["version"]
        for platform in platforms:
            releases = raw_by_version.get(version, {}).get(platform, [])
            if not releases:
                anomalies.append(
                    anomaly(
                        "supported_release_disappeared",
                        version,
                        current,
                        None,
                        f"trusted supported release {version} on {platform} is absent from the official manifest",
                        platform=platform,
                    )
                )
                continue
            if len(releases) > 1:
                continue
            release = releases[0]
            candidate = valid_release(release, policy_channel, platform)
            upstream = raw_release_metadata(release, platform)
            current_artifact = current["artifacts"][platform]
            if candidate is None:
                changed_fields = [
                    "revision" if current["revision"] != upstream["revision"] else None,
                    *(
                        field
                        for field in ARTIFACT_FIELDS
                        if current_artifact[field]
                        != (upstream["upstream_arch"] if field == "upstream_arch" else upstream[field])
                    ),
                ]
                changed_fields = [field for field in changed_fields if field is not None]
                anomalies.append(
                    anomaly(
                        "trusted_release_metadata_changed" if changed_fields else "supported_release_invalid_metadata",
                        version,
                        current,
                        upstream,
                        f"official metadata changed for trusted release {version} on {platform}"
                        if changed_fields
                        else f"official metadata for trusted release {version} on {platform} no longer passes the release filter",
                        changed_fields,
                        platform=platform,
                    )
                )
                continue
            changed_fields = [
                "revision" if current["revision"] != candidate["revision"] else None,
                *(
                    field
                    for field in ARTIFACT_FIELDS
                    if current_artifact[field] != candidate["artifacts"][platform][field]
                ),
            ]
            changed_fields = [field for field in changed_fields if field is not None]
            if changed_fields:
                anomalies.append(
                    anomaly(
                        "trusted_release_metadata_changed",
                        version,
                        current,
                        upstream,
                        f"official metadata changed for trusted release {version} on {platform}",
                        changed_fields,
                        platform=platform,
                    )
                )
    return sorted(
        anomalies,
        key=lambda item: (version_key(item["version"]), item.get("platform", ""), item["kind"]),
    )


def select_supported(
    candidates: dict[str, dict[str, Any]],
    current_entries: list[dict[str, Any]],
    minor_lines: int,
    platforms: list[str],
) -> list[dict[str, Any]]:
    latest_by_minor: dict[tuple[int, int], dict[str, Any]] = {}
    for candidate in candidates.values():
        if set(candidate.get("artifacts", {})) != set(platforms):
            continue
        parsed_version = version_key(candidate["version"])
        minor = parsed_version[:2]
        current = latest_by_minor.get(minor)
        if current is None or parsed_version > version_key(current["version"]):
            latest_by_minor[minor] = candidate
    current_minors = {version_key(entry["version"])[:2] for entry in current_entries}
    newest_current_minor = max(current_minors)
    selected_minors = sorted(
        minor
        for minor in latest_by_minor
        if minor in current_minors or minor > newest_current_minor
    )[-minor_lines:]
    return [latest_by_minor[minor] for minor in selected_minors]


def render_json(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def render_supported_table(entries: list[dict[str, Any]]) -> str:
    rows = [
        BEGIN_MARKER,
        "| Flutter | Platform | Channel | Git revision | SDK archive SHA256 |",
        "| --- | --- | --- | --- | --- |",
    ]
    rows.extend(
        f"| {entry['version']} | {platform} | {entry['channel']} | `{entry['revision']}` | `{entry['artifacts'][platform]['archive_sha256']}` |"
        for entry in entries
        for platform in sorted(entry["artifacts"])
    )
    rows.append(END_MARKER)
    return "\n".join(rows)


def replace_supported_table(readme: str, entries: list[dict[str, Any]]) -> str:
    pattern = re.compile(re.escape(BEGIN_MARKER) + r".*?" + re.escape(END_MARKER), re.DOTALL)
    matches = list(pattern.finditer(readme))
    if len(matches) != 1:
        raise UpdateError(
            f"README.md must contain exactly one generated supported-release block; found {len(matches)}"
        )
    return pattern.sub(render_supported_table(entries), readme, count=1)


def release_changes(old_entries: list[dict[str, Any]], new_entries: list[dict[str, Any]]) -> dict[str, Any]:
    old_by_minor = {version_key(entry["version"])[:2]: entry for entry in old_entries}
    new_by_minor = {version_key(entry["version"])[:2]: entry for entry in new_entries}

    patch_updates = [
        {"from": compact_entry(old_by_minor[minor]), "to": compact_entry(new_by_minor[minor])}
        for minor in sorted(old_by_minor.keys() & new_by_minor.keys())
        if old_by_minor[minor]["version"] != new_by_minor[minor]["version"]
    ]
    new_minors = [
        compact_entry(new_by_minor[minor])
        for minor in sorted(new_by_minor.keys() - old_by_minor.keys())
    ]
    retired = [
        compact_entry(old_by_minor[minor])
        for minor in sorted(old_by_minor.keys() - new_by_minor.keys())
    ]
    return {
        "patch_updates": patch_updates,
        "new_minors": new_minors,
        "retired": retired,
    }


def render_metadata(entry: dict[str, Any]) -> list[str]:
    lines = [f"  - revision: `{entry['revision']}`"]
    for platform in sorted(entry["artifacts"]):
        artifact = entry["artifacts"][platform]
        lines.extend(
            [
                f"  - platform: `{platform}`",
                f"    archive: `{artifact['archive']}`",
                f"    SHA256: `{artifact['archive_sha256']}`",
            ]
        )
    return lines


def render_json_for_markdown(value: Any) -> str:
    # Keep untrusted upstream strings inside the fenced JSON block.
    return json.dumps(value, indent=2, sort_keys=True).replace("`", "\\u0060")


def render_summary_markdown(summary: dict[str, Any]) -> str:
    if summary["status"] == "security_anomaly":
        lines = [
            "# Flutter release watcher: SECURITY ANOMALY",
            "",
            "No repository files were modified. Human review is required before the trust root changes.",
            "",
            "## Anomalies",
        ]
        for item in summary["anomalies"]:
            title = item["kind"].replace("_", " ").upper()
            platform = f" [{item['platform']}]" if item.get("platform") else ""
            lines.extend(["", f"### {title}: `{item['version']}`{platform}", f"{item['message']}."])
            if item.get("changed_fields"):
                lines.append(f"Changed fields: {', '.join(item['changed_fields'])}.")
            lines.extend(
                [
                    "",
                    "Trusted metadata:",
                    "```json",
                    render_json_for_markdown(item["old"]),
                    "```",
                    "",
                    "Upstream metadata:",
                    "```json",
                    render_json_for_markdown(item["upstream"]),
                    "```",
                ]
            )
        return "\n".join(lines) + "\n"

    lines = [
        "# Flutter support update",
        "",
        "This proposal was generated from the official Flutter Linux release manifest. Maintainer review and the ordinary PR CI gate remain required.",
        "",
        f"Update needed: {'yes' if summary['update_needed'] else 'no'}.",
    ]
    changes = summary["changes"]
    if not summary["update_needed"]:
        lines.extend(["", "No supported Flutter release update is needed."])
        return "\n".join(lines) + "\n"

    if changes["patch_updates"]:
        lines.extend(["", "## PATCH UPDATE"])
        for change in changes["patch_updates"]:
            lines.append(f"- `{change['from']['version']}` → `{change['to']['version']}`")
            lines.extend(render_metadata(change["to"]))
    if changes["new_minors"]:
        lines.extend(["", "## NEW MINOR"])
        for entry in changes["new_minors"]:
            lines.append(f"- + `{entry['version']}`")
            lines.extend(render_metadata(entry))
    if changes["retired"]:
        lines.extend(["", "## RETIRED"])
        for entry in changes["retired"]:
            lines.append(f"- - `{entry['version']}`")

    return "\n".join(lines) + "\n"


def atomic_write(path: Path, content: str) -> None:
    try:
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as temporary:
            temporary.write(content)
            temporary.flush()
            os.fchmod(temporary.fileno(), mode)
            temporary_path = Path(temporary.name)
        os.replace(temporary_path, path)
    except OSError as error:
        try:
            temporary_path.unlink()
        except (NameError, OSError):
            pass
        raise UpdateError(f"could not write {path}: {error}") from error


def write_summary(path: Path | None, content: str) -> None:
    if path is not None:
        atomic_write(path, content)


def build_summary(
    policy: dict[str, Any],
    old_entries: list[dict[str, Any]],
    new_entries: list[dict[str, Any]],
    manifest_changed: bool,
    readme_changed: bool,
) -> dict[str, Any]:
    changes = release_changes(old_entries, new_entries)
    return {
        "status": "update" if manifest_changed or readme_changed else "unchanged",
        "update_needed": manifest_changed or readme_changed,
        "files_changed": [
            path
            for path, changed in (
                ("supported_version.json", manifest_changed),
                ("README.md", readme_changed),
            )
            if changed
        ],
        "support_policy": policy,
        "changes": changes,
        "patch_updates": changes["patch_updates"],
        "new_minors": changes["new_minors"],
        "retired": changes["retired"],
        "supported_versions": [compact_entry(entry) for entry in new_entries],
        "anomalies": [],
    }


def build_anomaly_summary(policy: dict[str, Any], anomalies: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "status": "security_anomaly",
        "update_needed": False,
        "files_changed": [],
        "support_policy": policy,
        "changes": {"patch_updates": [], "new_minors": [], "retired": []},
        "patch_updates": [],
        "new_minors": [],
        "retired": [],
        "supported_versions": [],
        "anomalies": anomalies,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="report whether an update is needed")
    mode.add_argument("--write", action="store_true", help="write the deterministic manifest and README update")
    parser.add_argument(
        "--manifest",
        "--supported-version",
        "--supported-version-manifest",
        dest="manifest",
        default="supported_version.json",
    )
    parser.add_argument("--releases", default="releases_linux.json")
    parser.add_argument("--readme", default="README.md")
    parser.add_argument("--summary-json")
    parser.add_argument("--summary-markdown")
    parser.add_argument("paths", nargs="*", metavar="PATH", help="manifest releases_linux.json README.md")
    args = parser.parse_args()
    if args.paths:
        if len(args.paths) != 3:
            parser.error("positional inputs must be: manifest releases_linux.json README.md")
        args.manifest, args.releases, args.readme = args.paths
    return args


def run(args: argparse.Namespace) -> tuple[dict[str, Any], str]:
    manifest_path = Path(args.manifest)
    releases_path = Path(args.releases)
    readme_path = Path(args.readme)

    manifest = load_json(manifest_path, "supported version manifest")
    policy, old_entries, minor_lines = validate_supported_manifest(manifest, manifest_path)
    release_manifest = load_json(releases_path, "release manifest")
    candidates, raw_by_version = collect_releases(release_manifest, policy["channel"], policy["platforms"])
    anomalies = find_trust_anomalies(
        old_entries, candidates, raw_by_version, minor_lines, policy["platforms"], policy["channel"]
    )
    if anomalies:
        summary = build_anomaly_summary(policy, anomalies)
        return summary, render_summary_markdown(summary)

    new_entries = select_supported(candidates, old_entries, minor_lines, policy["platforms"])
    proposed_manifest = {
        "schema": manifest["schema"],
        "support_policy": policy,
        "supported_versions": new_entries,
    }
    manifest_content = render_json(proposed_manifest)
    generated_manifest = json.loads(manifest_content)
    readme = readme_path.read_text(encoding="utf-8")
    proposed_readme = replace_supported_table(readme, generated_manifest["supported_versions"])
    summary = build_summary(
        policy,
        old_entries,
        new_entries,
        manifest_content != manifest_path.read_text(encoding="utf-8"),
        proposed_readme != readme,
    )
    if args.write and summary["update_needed"]:
        if summary["files_changed"] == ["supported_version.json"]:
            atomic_write(manifest_path, manifest_content)
        elif summary["files_changed"] == ["README.md"]:
            atomic_write(readme_path, proposed_readme)
        else:
            atomic_write(manifest_path, manifest_content)
            atomic_write(readme_path, proposed_readme)
    return summary, render_summary_markdown(summary)


def main() -> int:
    args = parse_args()
    try:
        summary, markdown = run(args)
        write_summary(
            Path(args.summary_json) if args.summary_json else None,
            render_json(summary),
        )
        write_summary(
            Path(args.summary_markdown) if args.summary_markdown else None,
            markdown,
        )
        print(markdown, end="")
        if summary["status"] == "security_anomaly":
            return 1
        if args.check and summary["update_needed"]:
            return 1
        return 0
    except (OSError, UpdateError) as error:
        print(f"update-supported-versions: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
