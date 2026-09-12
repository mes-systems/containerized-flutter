#!/usr/bin/env python3
"""Refresh Docker Hub manifest digests in the supported base manifest."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, Mapping, NamedTuple
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


BEGIN_MARKER = "<!-- BEGIN GENERATED SUPPORTED BASES -->"
END_MARKER = "<!-- END GENERATED SUPPORTED BASES -->"
REGISTRY_URL = "https://registry-1.docker.io"
AUTH_URL = "https://auth.docker.io/token"
DEFAULT_TIMEOUT = 20.0
MANIFEST_ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)
MANIFEST_MEDIA_TYPES = frozenset(MANIFEST_ACCEPT.split(", "))
REPOSITORY_RE = re.compile(r"^[a-z0-9]+(?:[._-][a-z0-9]+)*$")
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-fA-F]{64}$")
REFERENCE_FIELD_RE = re.compile(r'(?<!\\)("reference"\s*:\s*)("(?:\\.|[^"\\])*")')
BASE_FIELDS = ("id", "family", "version", "variant", "reference")


class UpdateError(Exception):
    """A configuration, network, or upstream availability error."""


class SecurityAnomaly(UpdateError):
    """A response failed an integrity or trust-boundary check."""


class BaseReference(NamedTuple):
    repository: str
    tag: str
    digest: str
    tag_reference: str
    normalized_repository: str


class HTTPResponse(NamedTuple):
    status: int
    headers: Mapping[str, str]
    body: bytes


Transport = Callable[[str, Mapping[str, str], float], HTTPResponse]
Resolver = Callable[[BaseReference], str]


def _is_digest(value: Any) -> bool:
    return isinstance(value, str) and DIGEST_RE.fullmatch(value) is not None


def normalize_docker_hub_repository(repository: str) -> str:
    """Map an unqualified Docker Official Image name to library/<name>."""

    if not isinstance(repository, str) or not repository:
        raise UpdateError("Docker image repository must be a non-empty string")
    if repository.startswith("library/"):
        image_name = repository.removeprefix("library/")
        if REPOSITORY_RE.fullmatch(image_name):
            return repository
    if "/" in repository:
        raise UpdateError(
            "unsupported registry/source; only unqualified Docker Hub official images are supported"
        )
    if REPOSITORY_RE.fullmatch(repository) is None:
        raise UpdateError(f"invalid Docker image repository: {repository}")
    return f"library/{repository}"


def parse_base_reference(reference: str) -> BaseReference:
    """Parse repository:tag@sha256:digest and reject non-Official-Image sources."""

    if not isinstance(reference, str) or not reference or any(char.isspace() for char in reference):
        raise UpdateError("invalid base reference")
    image_part = reference.split("@", 1)[0]
    if "/" in image_part:
        raise UpdateError(
            "unsupported registry/source; only unqualified Docker Hub official images are supported"
        )
    if reference.count("@") == 0:
        raise UpdateError("base reference is missing an immutable digest")
    if reference.count("@") != 1:
        raise UpdateError("invalid base reference")

    image_reference, digest = reference.split("@", 1)
    if not _is_digest(digest):
        raise UpdateError("base reference must use a sha256 digest")
    if ":" not in image_reference:
        raise UpdateError("base reference is missing a tag")

    repository, tag = image_reference.rsplit(":", 1)
    if REPOSITORY_RE.fullmatch(repository) is None:
        raise UpdateError("invalid base reference repository")
    if TAG_RE.fullmatch(tag) is None:
        raise UpdateError("invalid base reference tag")
    return BaseReference(
        repository=repository,
        tag=tag,
        digest=digest,
        tag_reference=image_reference,
        normalized_repository=normalize_docker_hub_repository(repository),
    )


def _header(response: HTTPResponse, name: str) -> str | None:
    wanted = name.lower()
    for key, value in response.headers.items():
        if str(key).lower() == wanted:
            return str(value).strip()
    return None


def _transport_call(transport: Transport, url: str, headers: Mapping[str, str], timeout: float) -> HTTPResponse:
    try:
        response = transport(url, headers, timeout)
    except (OSError, TimeoutError, HTTPError) as error:
        raise UpdateError(f"network error ({type(error).__name__})") from error
    if not isinstance(response, HTTPResponse):
        raise UpdateError("HTTP transport returned an invalid response")
    return response


def urllib_transport(url: str, headers: Mapping[str, str], timeout: float) -> HTTPResponse:
    """Perform one GET without exposing response or authorization data in errors."""

    request = Request(url, headers=dict(headers), method="GET")
    try:
        with urlopen(request, timeout=timeout) as response:
            return HTTPResponse(
                status=int(response.status),
                headers={str(key): str(value) for key, value in response.headers.items()},
                body=response.read(),
            )
    except HTTPError as error:
        return HTTPResponse(
            status=int(error.code),
            headers={str(key): str(value) for key, value in error.headers.items()}
            if error.headers
            else {},
            body=error.read(),
        )


def request_pull_token(
    repository: str,
    transport: Transport = urllib_transport,
    timeout: float = DEFAULT_TIMEOUT,
) -> str:
    normalized_repository = normalize_docker_hub_repository(repository)
    query = urlencode(
        {
            "service": "registry.docker.io",
            "scope": f"repository:{normalized_repository}:pull",
        }
    )
    response = _transport_call(
        transport,
        f"{AUTH_URL}?{query}",
        {"Accept": "application/json"},
        timeout,
    )
    if response.status != 200:
        raise UpdateError(f"Docker Hub token request failed with HTTP {response.status}")
    try:
        payload = json.loads(response.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise UpdateError("Docker Hub token response was malformed JSON") from error
    if not isinstance(payload, dict):
        raise UpdateError("Docker Hub token response did not contain a valid token")

    token_present = "token" in payload
    access_token_present = "access_token" in payload
    token = payload.get("token")
    access_token = payload.get("access_token")
    for name, value, present in (
        ("token", token, token_present),
        ("access_token", access_token, access_token_present),
    ):
        if present and (
            not isinstance(value, str)
            or not value
            or any(char.isspace() for char in value)
        ):
            raise UpdateError(f"Docker Hub token response contained an invalid {name}")
    if token_present and access_token_present and token != access_token:
        raise UpdateError("Docker Hub token response contained conflicting token fields")
    if token_present:
        return token
    if access_token_present:
        return access_token
    raise UpdateError("Docker Hub token response did not contain a valid token")


def fetch_manifest(
    repository: str,
    reference: str,
    token: str,
    transport: Transport = urllib_transport,
    timeout: float = DEFAULT_TIMEOUT,
) -> HTTPResponse:
    normalized_repository = normalize_docker_hub_repository(repository)
    if not isinstance(reference, str) or not reference or "/" in reference:
        raise UpdateError("invalid Docker manifest reference")
    url = (
        f"{REGISTRY_URL}/v2/{quote(normalized_repository, safe='/')}/manifests/"
        f"{quote(reference, safe=':._-')}"
    )
    return _transport_call(
        transport,
        url,
        {
            "Accept": MANIFEST_ACCEPT,
            "Authorization": f"Bearer {token}",
        },
        timeout,
    )


def _manifest_media_type(response: HTTPResponse) -> str:
    content_type = _header(response, "Content-Type")
    media_type = content_type.split(";", 1)[0].strip().lower() if content_type else ""
    if media_type not in MANIFEST_MEDIA_TYPES:
        raise SecurityAnomaly("manifest response has an unexpected Content-Type")
    return media_type


def _validate_manifest_document(media_type: str, body: bytes) -> None:
    try:
        document = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SecurityAnomaly("manifest response body is not valid JSON") from error
    if not isinstance(document, dict) or document.get("schemaVersion") != 2:
        raise SecurityAnomaly("manifest response has an unexpected OCI/Docker structure")

    if media_type in {
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    }:
        descriptors = document.get("manifests")
        if not isinstance(descriptors, list) or not descriptors:
            raise SecurityAnomaly("manifest index contains no valid manifest descriptors")
        for descriptor in descriptors:
            if not isinstance(descriptor, dict) or not _is_digest(descriptor.get("digest")):
                raise SecurityAnomaly("manifest index contains an invalid descriptor")
        return

    config = document.get("config")
    layers = document.get("layers")
    if not isinstance(config, dict) or not _is_digest(config.get("digest")) or not isinstance(layers, list):
        raise SecurityAnomaly("image manifest has an unexpected OCI/Docker structure")
    for layer in layers:
        if not isinstance(layer, dict) or not _is_digest(layer.get("digest")):
            raise SecurityAnomaly("image manifest contains an invalid layer descriptor")


def verify_manifest(
    response: HTTPResponse,
    expected_digest: str | None = None,
    require_header: bool = True,
) -> str:
    """Verify media type, manifest structure, body hash, and registry digest header."""

    if response.status != 200:
        raise SecurityAnomaly(f"manifest request returned unexpected HTTP {response.status}")
    if not isinstance(response.body, bytes):
        raise SecurityAnomaly("manifest response body was not returned as bytes")
    media_type = _manifest_media_type(response)
    _validate_manifest_document(media_type, response.body)
    computed_digest = f"sha256:{hashlib.sha256(response.body).hexdigest()}"
    header_digest = _header(response, "Docker-Content-Digest")
    if (
        require_header and not _is_digest(header_digest)
    ) or (
        header_digest is not None
        and (not _is_digest(header_digest) or header_digest.lower() != computed_digest)
    ):
        raise SecurityAnomaly("manifest body digest does not match Docker-Content-Digest")
    if expected_digest is not None and computed_digest != expected_digest.lower():
        raise SecurityAnomaly("digest-addressed manifest did not reproduce the requested digest")
    return computed_digest


def _raise_manifest_status(status: int, tag_reference: str, digest_request: bool) -> None:
    if status in {401, 403, 429} or status >= 500:
        raise UpdateError(f"Docker Hub manifest request failed with HTTP {status}")
    if status == 404:
        if digest_request:
            raise SecurityAnomaly("digest-addressed manifest re-fetch returned HTTP 404")
        raise SecurityAnomaly(f"trusted supported tag {tag_reference} returned HTTP 404")
    raise UpdateError(f"Docker Hub manifest request failed with HTTP {status}")


def resolve_tag_digest(
    repository: str,
    tag: str,
    transport: Transport = urllib_transport,
    timeout: float = DEFAULT_TIMEOUT,
) -> str:
    """Resolve one mutable Docker Hub tag to a verified top-level manifest digest."""

    normalized_repository = normalize_docker_hub_repository(repository)
    token = request_pull_token(normalized_repository, transport=transport, timeout=timeout)
    tag_reference = f"{repository}:{tag}"
    tagged = fetch_manifest(
        normalized_repository,
        tag,
        token,
        transport=transport,
        timeout=timeout,
    )
    if tagged.status != 200:
        _raise_manifest_status(tagged.status, tag_reference, digest_request=False)
    digest = verify_manifest(tagged)

    digest_response = fetch_manifest(
        normalized_repository,
        digest,
        token,
        transport=transport,
        timeout=timeout,
    )
    if digest_response.status != 200:
        _raise_manifest_status(digest_response.status, tag_reference, digest_request=True)
    verify_manifest(digest_response, expected_digest=digest, require_header=False)
    return digest


def _require_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value or any(char.isspace() for char in value):
        raise UpdateError(f"{name} must be a non-empty string without whitespace")
    return value


def validate_supported_manifest(manifest: Any, path: Path | None = None) -> list[tuple[dict[str, Any], BaseReference]]:
    """Validate the schema while allowing future multi-base entries."""

    location = f"{path}: " if path is not None else ""
    if not isinstance(manifest, dict):
        raise UpdateError(f"{location}manifest must be an object")
    if type(manifest.get("schema")) is not int or manifest["schema"] != 1:
        raise UpdateError(f"{location}schema must be 1")
    if set(manifest) != {"schema", "bases"}:
        raise UpdateError(f"{location}top-level fields must be exactly schema and bases")
    bases = manifest.get("bases")
    if not isinstance(bases, list) or not bases:
        raise UpdateError(f"{location}bases must be a non-empty array")

    entries: list[tuple[dict[str, Any], BaseReference]] = []
    seen_ids: set[str] = set()
    for index, candidate in enumerate(bases):
        entry_location = f"{location}bases[{index}]"
        if not isinstance(candidate, dict) or set(candidate) != set(BASE_FIELDS):
            raise UpdateError(f"{entry_location} must contain exactly the allowed fields")
        base_id = _require_string(candidate.get("id"), f"{entry_location}.id")
        if re.fullmatch(r"[a-z0-9]+([.-][a-z0-9]+)*", base_id) is None:
            raise UpdateError(f"{entry_location}.id is invalid")
        if base_id in seen_ids:
            raise UpdateError(f"duplicate base id: {base_id}")
        seen_ids.add(base_id)
        family = _require_string(candidate.get("family"), f"{entry_location}.family")
        _require_string(candidate.get("version"), f"{entry_location}.version")
        _require_string(candidate.get("variant"), f"{entry_location}.variant")
        reference = _require_string(candidate.get("reference"), f"{entry_location}.reference")
        parsed = parse_base_reference(reference)
        if parsed.repository != family:
            raise UpdateError(f"reference repository does not match family for {base_id}")
        entries.append((candidate, parsed))
    return entries


def _detail(base: dict[str, Any], parsed: BaseReference, message: str, kind: str | None = None) -> dict[str, str]:
    result = {
        "base_id": str(base["id"]),
        "tag_reference": parsed.tag_reference,
        "message": message,
    }
    if kind is not None:
        result["kind"] = kind
    return result


def calculate_updates(
    manifest: dict[str, Any],
    resolver: Resolver | None = None,
    transport: Transport = urllib_transport,
    timeout: float = DEFAULT_TIMEOUT,
) -> dict[str, Any]:
    """Resolve every base independently and calculate a side-effect-free summary."""

    entries = validate_supported_manifest(manifest)
    changes: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []
    anomalies: list[dict[str, str]] = []
    for base, parsed in entries:
        try:
            new_digest = (
                resolver(parsed)
                if resolver is not None
                else resolve_tag_digest(
                    parsed.normalized_repository,
                    parsed.tag,
                    transport=transport,
                    timeout=timeout,
                )
            )
            if not _is_digest(new_digest):
                raise SecurityAnomaly("resolver returned an invalid manifest digest")
        except SecurityAnomaly as error:
            anomalies.append(_detail(base, parsed, str(error), "manifest_integrity_failure"))
            continue
        except UpdateError as error:
            errors.append(_detail(base, parsed, str(error)))
            continue

        if parsed.digest.lower() != new_digest.lower():
            changes.append(
                {
                    "base_id": base["id"],
                    "tag_reference": parsed.tag_reference,
                    "old_digest": parsed.digest,
                    "new_digest": new_digest,
                }
            )

    if anomalies:
        status = "security_anomaly"
    elif errors:
        status = "error"
    elif changes:
        status = "update"
    else:
        status = "unchanged"
    return {
        "status": status,
        "update_needed": status == "update",
        "changes": changes if status == "update" else [],
        "anomalies": anomalies,
        "errors": errors,
        "files_changed": ["supported_bases.json", "README.md"] if status == "update" else [],
    }


def _short_digest(digest: str) -> str:
    return f"sha256:{digest.split(':', 1)[1][:12]}..."


def render_supported_bases(bases: list[dict[str, Any]] | dict[str, Any]) -> str:
    """Render the generated README table in manifest order."""

    entries = bases["bases"] if isinstance(bases, dict) else bases
    lines = [
        BEGIN_MARKER,
        "| Base ID | Family | Version | Variant | Digest |",
        "| --- | --- | --- | --- | --- |",
    ]
    for base in entries:
        parsed = parse_base_reference(base["reference"])
        lines.append(
            f"| `{base['id']}` | {base['family']} | {base['version']} | "
            f"{base['variant']} | `{_short_digest(parsed.digest)}` |"
        )
    lines.append(END_MARKER)
    return "\n".join(lines)


def render_readme(readme: str, bases: list[dict[str, Any]] | dict[str, Any]) -> str:
    """Replace exactly one generated base block and fail closed on marker damage."""

    begin_count = readme.count(BEGIN_MARKER)
    end_count = readme.count(END_MARKER)
    if begin_count != 1 or end_count != 1:
        raise UpdateError(
            "README.md must contain exactly one generated supported-base block "
            f"(found {begin_count} begin and {end_count} end markers)"
        )
    begin = readme.index(BEGIN_MARKER)
    end = readme.index(END_MARKER)
    if begin > end:
        raise UpdateError("README.md generated supported-base markers are reversed")
    end += len(END_MARKER)
    return readme[:begin] + render_supported_bases(bases) + readme[end:]


def render_manifest_references(
    manifest_text: str,
    manifest: dict[str, Any],
    resolved_by_id: Mapping[str, str],
) -> str:
    """Change only reference string values, preserving JSON formatting and field order."""

    bases = manifest["bases"]
    matches = list(REFERENCE_FIELD_RE.finditer(manifest_text))
    if len(matches) != len(bases):
        raise UpdateError("supported_bases.json does not contain one reference field per base")

    replacements: list[tuple[int, int, str]] = []
    for match, base in zip(matches, bases):
        try:
            raw_reference = json.loads(match.group(2))
        except json.JSONDecodeError as error:
            raise UpdateError("supported_bases.json contains an invalid reference string") from error
        if raw_reference != base["reference"]:
            raise UpdateError("supported_bases.json reference fields do not match parsed bases")
        digest = resolved_by_id.get(base["id"])
        if digest is None:
            digest = parse_base_reference(base["reference"]).digest
        new_reference = f"{parse_base_reference(base['reference']).tag_reference}@{digest}"
        if new_reference != base["reference"]:
            replacements.append((match.start(2), match.end(2), json.dumps(new_reference)))

    result = manifest_text
    for start, end, replacement in reversed(replacements):
        result = result[:start] + replacement + result[end:]
    return result


def _json_text(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def render_summary_markdown(summary: dict[str, Any]) -> str:
    status = summary["status"]
    if status == "update":
        lines = [
            "# Base image updates",
            "",
            "| Base | Tag | Previous digest | Current digest |",
            "| --- | --- | --- | --- |",
        ]
        lines.extend(
            f"| {change['base_id']} | {change['tag_reference']} | "
            f"`{change['old_digest']}` | `{change['new_digest']}` |"
            for change in summary["changes"]
        )
        lines.extend(
            [
                "",
                "This PR was generated from the current upstream Docker Hub manifest.",
                "",
                "Merging it will use the ordinary selective publication path.",
            ]
        )
        return "\n".join(lines) + "\n"

    if status == "security_anomaly":
        lines = [
            "# Base image watcher: SECURITY ANOMALY",
            "",
            "No repository files were modified. Human review is required before the trust root changes.",
            "",
            "## Anomalies",
        ]
        for item in summary["anomalies"]:
            if "base_id" in item:
                lines.append(f"- `{item['base_id']}` ({item['tag_reference']}): {item['message']}.")
            else:
                lines.append(f"- {item['message']}.")
        return "\n".join(lines) + "\n"

    if status == "error":
        lines = [
            "# Base image watcher: ERROR",
            "",
            "No repository files were modified. The watcher will retry on its next run.",
            "",
            "## Errors",
        ]
        for item in summary["errors"]:
            if "base_id" in item:
                lines.append(f"- `{item['base_id']}` ({item['tag_reference']}): {item['message']}.")
            else:
                lines.append(f"- {item['message']}.")
        return "\n".join(lines) + "\n"

    return "# Base image watcher\n\nNo supported base image digest update is needed.\n"


def load_json(path: Path, description: str) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as error:
        raise UpdateError(f"{description} not found: {path}") from error
    except OSError as error:
        raise UpdateError(f"could not read {description} {path}") from error
    except json.JSONDecodeError as error:
        raise UpdateError(f"invalid JSON in {description} {path}") from error


def atomic_write(path: Path, content: str) -> None:
    temporary_path: Path | None = None
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
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except OSError:
                pass
        raise UpdateError(f"could not write {path}") from error


def write_summary(path: Path | None, content: str) -> None:
    if path is not None:
        atomic_write(path, content)


def _error_summary(error: Exception) -> dict[str, Any]:
    return {
        "status": "security_anomaly" if isinstance(error, SecurityAnomaly) else "error",
        "update_needed": False,
        "changes": [],
        "anomalies": [{"message": str(error), "kind": "watcher_failure"}]
        if isinstance(error, SecurityAnomaly)
        else [],
        "errors": [] if isinstance(error, SecurityAnomaly) else [{"message": str(error)}],
        "files_changed": [],
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default="supported_bases.json")
    parser.add_argument("--readme", default="README.md")
    parser.add_argument("--summary-json")
    parser.add_argument("--summary-markdown")
    parser.add_argument("--write", action="store_true", help="write changed manifest and README")
    parser.add_argument("--check", action="store_true", help="return 1 when an update is needed")
    args = parser.parse_args(argv)
    if args.write and args.check:
        parser.error("--write and --check are mutually exclusive")
    return args


def run(
    args: argparse.Namespace,
    resolver: Resolver | None = None,
    transport: Transport = urllib_transport,
) -> tuple[dict[str, Any], str]:
    manifest_path = Path(args.manifest)
    readme_path = Path(args.readme)
    manifest_text = manifest_path.read_text(encoding="utf-8")
    manifest = load_json(manifest_path, "supported base manifest")
    summary = calculate_updates(manifest, resolver=resolver, transport=transport)
    if summary["status"] in {"error", "security_anomaly", "unchanged"}:
        if summary["status"] == "unchanged":
            readme = readme_path.read_text(encoding="utf-8")
            render_readme(readme, manifest)
        return summary, render_summary_markdown(summary)

    resolved_by_id = {change["base_id"]: change["new_digest"] for change in summary["changes"]}
    proposed_manifest = copy.deepcopy(manifest)
    for base in proposed_manifest["bases"]:
        digest = resolved_by_id.get(base["id"], parse_base_reference(base["reference"]).digest)
        base["reference"] = f"{parse_base_reference(base['reference']).tag_reference}@{digest}"
    readme = readme_path.read_text(encoding="utf-8")
    proposed_readme = render_readme(readme, proposed_manifest)
    proposed_manifest_text = render_manifest_references(manifest_text, manifest, resolved_by_id)
    if args.write:
        atomic_write(manifest_path, proposed_manifest_text)
        atomic_write(readme_path, proposed_readme)
    return summary, render_summary_markdown(summary)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        summary, markdown = run(args)
    except (OSError, json.JSONDecodeError, UpdateError) as error:
        summary = _error_summary(error)
        markdown = render_summary_markdown(summary)

    try:
        write_summary(
            Path(args.summary_json) if args.summary_json else None,
            _json_text(summary),
        )
        write_summary(
            Path(args.summary_markdown) if args.summary_markdown else None,
            markdown,
        )
    except UpdateError as error:
        print(f"update-supported-bases: {error}", file=sys.stderr)
        return 1

    print(markdown, end="")
    if summary["status"] in {"error", "security_anomaly"}:
        return 1
    if args.check and summary["update_needed"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
