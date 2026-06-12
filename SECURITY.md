# Security Policy

VideoToolbox Remote is designed for trusted LAN use. Do not expose `vtremoted` directly to the public internet.

## Supported Versions

Security fixes are made against the latest released version and `main`.

## Deployment Guidance

- Bind to loopback unless LAN clients need direct access.
- Prefer SSH tunnels, VPN, or network isolation for untrusted networks.
- Use token authentication where appropriate, preferably `--token-file` or `--token-env`.
- Do not pass long-lived secrets with `--token` on shared systems because command-line arguments can appear in process listings.

See [docs/security.md](docs/security.md) for setup examples.

## Reporting a Vulnerability

Do not open a public issue for suspected vulnerabilities.

Use GitHub private vulnerability reporting for this repository:
https://github.com/davelindo/videotoolbox_remote/security/advisories/new

Please include the affected version or commit, deployment mode, network exposure, reproduction steps, and any relevant logs.
