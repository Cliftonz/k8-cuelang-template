# Security Policy

## This is a template

Every credential, hostname, IP, account ID, and email in this repository is a
**placeholder**. There are no real secrets committed here. Before you deploy,
replace the placeholder values (see the *Placeholders* section of the
[README](README.md)) and wire your own secret store.

## Secret handling

This template stores **no secret values in git**. It uses
[External Secrets Operator](https://external-secrets.io): each `ExternalSecret`
references a path in a secret store (OpenBao/Vault), and the value is materialised
into the cluster at runtime. See [docs/secret-management.md](docs/secret-management.md).

When adapting this template:

- Never commit private keys, tokens, kubeconfigs, or `.env` files. The
  [`.gitignore`](.gitignore) blocks the common patterns (`*.pem`, `*.key`,
  `*-secret.yaml`, `.env*`) — keep it that way.
- Keep opaque IDs (OAuth client IDs, cloud account IDs) in your secret store, not
  inline in CUE, when they are sensitive in your environment.
- Run a secret scanner (e.g. `gitleaks`, `trufflehog`) in CI on your fork.

## Reporting a vulnerability

If you find a security issue in the template itself (for example, an insecure
default in a Composition or policy), please open a private security advisory on the
GitHub repository rather than a public issue.
