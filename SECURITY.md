# Security policy

## Supported versions

Security fixes go into the latest release. Testa is pre-1.0, so please upgrade
(`brew upgrade testa`) before reporting.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them
privately through GitHub:
[**Report a vulnerability**](https://github.com/valewnrt/testa/security/advisories/new).

Include the Testa version (`testa version`), your macOS and Xcode versions, and
steps to reproduce. You'll get a reply within a week. Once a fix is released,
the advisory is published and you're credited unless you'd rather not be.

## Scope

Testa runs locally and drives apps you may not trust. In scope, for example:

- another local user reaching a Testa daemon socket
- a file write escaping its path guard
- app-controlled text (labels, OCR, logs) breaking out of its escaping in
  snapshots or MCP replies
- a crafted accessibility tree or screen hanging or crashing the daemon

The design is described in [docs/security.md](docs/security.md). Prompt
injection through on-screen text that is *correctly labelled as data* is a
known limit of any agent tool and is documented there.
