# Security Policy

## Supported versions

The authoritative supported Flutter releases are listed in
[`supported_version.json`](supported_version.json). Its `support_policy` defines
the stable channel, the number of minor lines retained, and the selection of the
latest supported patch for each line. The authoritative supported base images
are listed in [`supported_bases.json`](supported_bases.json). These manifests,
not a separate version list in this policy, define the current support matrix.

Historical image tags that are no longer present in the current manifests may
remain available, but may no longer be rebuilt or receive security fixes.

## Reporting a vulnerability

**Do not report security vulnerabilities through public GitHub Issues.**

The primary reporting mechanism for vulnerabilities owned by this repository is
GitHub Private Vulnerability Reporting: open the repository's **Security** tab
and select **Report a vulnerability**. Private vulnerability reporting is
enabled for this repository. Reports are handled privately through GitHub's
security advisory workflow where appropriate.

Useful information includes, where applicable:

- The affected image tag and preferably its immutable OCI digest.
- The affected Flutter version, base image, and component.
- The security impact and relevant attacker capabilities or prerequisites.
- Reproduction steps or a proof of concept.
- The expected versus actual security property.
- Whether you suspect the issue originates in Flutter, Ubuntu, Debian, or
  another upstream dependency.

Please share only information needed for triage. Do not include credentials,
private keys, access tokens, or sensitive production data.

## Vulnerability ownership and upstream routing

`containerized-flutter` packages and distributes upstream software, so a
vulnerability found in an image does not necessarily originate in this
repository.

| Report to | Examples |
| --- | --- |
| `mes-systems/containerized-flutter` | Vulnerabilities introduced by our Dockerfile or runtime image configuration; failures in our Flutter artifact acquisition or verification scripts, including the ability to substitute or tamper with downloaded artifacts; base-image integrity, pinning, or build-logic mistakes; GitHub Actions, CI, or publish-pipeline vulnerabilities; workflow credential or permission problems; published-image digest integrity failures; provenance, SBOM, or attestation correctness or integrity failures; and supported images that remain vulnerable after an upstream fix because of our build, pinning, update, or publication process. Report here as well if you reasonably believe our changes worsen an upstream security impact. |
| Flutter | Report vulnerabilities originating in Flutter through Google's vulnerability intake at [g.co/vulnz](https://g.co/vulnz), following the [official Flutter security policy](https://github.com/flutter/.github/blob/main/SECURITY.md) as the canonical reference for current procedures. |
| Ubuntu | Vulnerabilities originating in Ubuntu or Ubuntu packages should follow the [Ubuntu Security Team's disclosure and reporting policy](https://ubuntu.com/security/disclosure-policy). |
| Debian | Vulnerabilities originating in Debian or Debian packages should follow the [Debian Security Team's reporting guidance](https://www.debian.org/security/faq). |

If you are unsure whether a vulnerability belongs to this repository or an
upstream project, you may still report it privately to us. We can triage and
route it; reporters do not need to understand the complete build architecture.
A vulnerability may also require both an upstream report and remediation in
`containerized-flutter`.

## Coordinated disclosure

Please do not publicly disclose exploitable details before maintainers have had
a reasonable opportunity to investigate and ship a remediation. We will use
GitHub Security Advisories and private vulnerability reporting for private
coordination where appropriate. The project does not guarantee a response or
remediation timeline.
