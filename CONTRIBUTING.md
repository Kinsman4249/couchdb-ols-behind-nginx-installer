# Contributing to couchdb-ols-behind-nginx-installer

Thanks for taking the time to contribute. This is a small, focused installer, so the guidelines are light.

## Ground rules

- Open an issue before a large change so the approach can be discussed. For early discussion, explaining the use case (the why) is more useful than the proposed patch (the what).
- Keep the installer POSIX-friendly bash and avoid adding heavy dependencies. The whole point is a native, no-Docker, low-footprint setup.
- Do not commit secrets. No tokens, passwords, or private keys in code, examples, or fixtures.

## Making a change

1. Fork the repository and create a branch off the default branch.
2. Make your change. Keep commits focused and messages descriptive.
3. Test your change. See the Testing section of the README for how to verify locally.
4. Add a numbered entry to CHANGELOG.md under the current round.
5. Open a pull request using the template and describe what changed and why.

## Style

- Shell: prefer `set -euo pipefail`, quote variables, and comment anything non-obvious.
- nginx: keep vhost fragments minimal and comment any directive that has a security or correctness reason.
- Docs: plain ASCII, no smart quotes.

## Reporting security issues

Please do not open a public issue for a vulnerability. See SECURITY.md for how to report privately.
