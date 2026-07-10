# Security Policy

## Supported Versions

<table>
  <thead>
    <tr><th>Version</th><th>Supported</th></tr>
  </thead>
  <tbody>
    <tr><td>0.1.x</td><td>Yes</td></tr>
    <tr><td>&lt; 0.1</td><td>No</td></tr>
  </tbody>
</table>

## Reporting a Vulnerability

Please report security issues privately rather than opening a public issue.

Preferred: use GitHub's private vulnerability reporting on the repository at https://github.com/Kinsman4249/couchdb-ols-behind-nginx-installer (Security tab, Report a vulnerability). If that is unavailable, open a minimal issue asking for a private contact channel, without disclosing details.

When reporting, please include:

- A description of the issue and its impact.
- Steps to reproduce, with any relevant configuration (redact secrets).
- The commit SHA or release tag affected.

## Scope and notes

- This project is an installer that configures CouchDB, nginx, and certbot. Vulnerabilities in those upstream projects should be reported to their respective maintainers; issues in how this installer configures them are in scope here.
- Never include real passwords, API tokens, or private keys in a report. Redact them.

## Response

Reports will be acknowledged and triaged as quickly as is practical for a small project. Fixes will be released as a new tagged version with a corresponding CHANGELOG entry.
