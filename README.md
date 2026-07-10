# couchdb-ols-behind-nginx-installer

Native (no-Docker) CouchDB backend for Obsidian Self-hosted LiveSync on Debian, fronted by an existing nginx reverse proxy using SNI. Every hostname, credential, token, path, and the TLS method are prompted for at runtime. Nothing is hardcoded.

## What it sets up

- CouchDB installed natively from the Apache Debian repository, bound to 127.0.0.1:5984 only. nginx is the sole public entry point.
- CouchDB admin created at install time (CouchDB 3.x will not start without one).
- The maintainer's couchdb-init.sh applied (enables CORS, sets the Obsidian allowed origins, require_valid_user, max_document_size).
- The vault database created and ready.
- An nginx SNI vhost on 443 that proxies to CouchDB, with:
  - Optional extra include files you specify (for an origin lockdown, real-ip, mTLS, etc.).
  - HSTS scoped to this host only.
  - client_max_body_size 0 so large notes and attachments are not truncated.
  - A generous request rate limit as an anti-abuse net.
- A TLS certificate obtained by your chosen method (see below), or reuse of a certificate you already have.
- An optional 444 default_server that drops unknown-SNI and raw-IP hits on 443.

## Prerequisites

- Debian (Debian 11 or 12 class systems).
- An existing nginx install with the standard sites-available / sites-enabled / conf.d layout.
- A user with sudo (the script re-execs itself under sudo if not run as root).
- For DNS-01 TLS: the appropriate certbot DNS plugin package name, authenticator name, and a credentials file (or its contents ready to paste). Any provider certbot supports will work.

## TLS options (prompted)

1. certbot DNS-01 plugin. You supply the plugin package (for example python3-certbot-dns-cloudflare), the authenticator name (for example dns-cloudflare), a credentials file path, and an email. Recommended when the host sits behind a proxy or firewall that would block HTTP-01.
2. certbot webroot (HTTP-01). You supply a webroot path and an email.
3. certbot standalone (HTTP-01). Needs port 80 free; certbot binds it briefly.
4. Bring your own certificate. You supply the fullchain and private key paths.
5. Skip. The vhost is written but not enabled until a certificate exists.

The vhost is only enabled once both the certificate and key files are present, so a config test cannot fail on a missing certificate path.

## Install directly on the Debian host

Clone the repo so the nginx/ folder travels with the script (the script reads those files relative to its own location):

    sudo apt-get update && sudo apt-get install -y git
    git clone https://github.com/Kinsman4249/couchdb-ols-behind-nginx-installer.git
    cd couchdb-ols-behind-nginx-installer
    sudo bash install-ols-couchdb.sh

Answer the prompts. The script prints a summary of everything you need to write down at the end.

## Obsidian plugin setup

Install the Self-hosted LiveSync community plugin and set:

- URI: https:// followed by the hostname you chose
- Username and Password: the CouchDB admin credentials from the install summary
- Database: the vault database name from the summary
- Set an End-to-End encryption passphrase. The server never sees it. Record it separately.

## Testing

- Confirm CouchDB is localhost-only: `ss -tlnp | grep 5984` should show 127.0.0.1:5984, not 0.0.0.0.
- Confirm auth is enforced: a request to https:// your host without credentials should return 401, not the CouchDB welcome.
- Confirm nginx config: `sudo nginx -t`.
- Confirm the cert lineage is separate: `sudo certbot certificates` should list your new host as its own certificate, leaving existing certs unchanged.
- In Obsidian, run the plugin connection check; it should report a successful connection and database access.

## Security notes

- CouchDB is never exposed directly. Only nginx on 443 is public.
- require_valid_user is enabled, so every request requires authentication.
- Use a strong CouchDB admin password and enable plugin End-to-End encryption so vault contents are ciphertext at rest.
- Scope any DNS API token to the minimum needed (DNS edit on a single zone).

## Protecting the endpoint with a Cloudflare origin lockdown

This installer intentionally does not hardcode any Cloudflare or origin-lockdown configuration. If your host sits behind Cloudflare and you want to reject any traffic that does not arrive through Cloudflare (direct-to-origin scans, raw-IP hits), apply a lockdown after this installer completes.

A ready-made option is CloudFlareDebianHardener (OwnTracks flavoured):

  https://github.com/Kinsman4249/CloudFlareDebianHardener-OwnTrackFlavouredHardener

That project generates nginx snippets that pin real client IPs to Cloudflare ranges, enable Authenticated Origin Pulls (mTLS from Cloudflare), and return 403 to anything that is not Cloudflare, localhost, or an explicit allowlist. It is the same pattern used by the OwnTracks vhost this installer was designed to coexist with.

### How to combine it with this installer

1. Put the hostname behind Cloudflare (orange cloud / proxied). If you use a CNAME to another proxied hostname on the same origin, set the proxy toggle on the record itself; proxy status is per-record, not inherited.

2. Run CloudFlareDebianHardener first (or before enabling this vhost) so its snippet files exist on disk. Typically they land in /etc/nginx/snippets/, for example:
   - /etc/nginx/snippets/cloudflare-realip.conf
   - /etc/nginx/snippets/cloudflare-mtls.conf
   - /etc/nginx/snippets/cloudflare-enforce.conf
   Follow that project's README for the exact filenames and setup, including installing the Cloudflare Authenticated Origin Pull CA it references.

3. Run this installer. At the "Extra include file paths" prompt, paste the full paths of the hardener snippets separated by spaces, for example:
   /etc/nginx/snippets/cloudflare-realip.conf /etc/nginx/snippets/cloudflare-mtls.conf /etc/nginx/snippets/cloudflare-enforce.conf
   The installer inserts them inside the generated vhost, so this endpoint gets the same origin lockdown as the rest of your Cloudflare-fronted services.

4. If you did not run the hardener before this installer, leave the "Extra include file paths" prompt blank, run the hardener afterward, then add the include lines to /etc/nginx/sites-available/obsidian-livesync by hand and reload nginx.

### Important interaction

The enforce snippet returns 403 to any non-Cloudflare client. Because of that:

- Keep the hostname orange-clouded (proxied) whenever the enforce include is active. If you switch the record to DNS-only (grey) while the enforce snippet is included, every direct client, including the Obsidian plugin, will receive 403.
- Do not use certbot HTTP-01 (webroot or standalone) for renewal while the enforce snippet is active, because the Let's Encrypt validation servers are not Cloudflare IPs and will be blocked. Use the certbot DNS-01 TLS option in this installer, which validates over DNS and is unaffected by the origin lockdown.

## Caveats

- debconf keys for CouchDB (mode, bindaddress, cookie, adminpass) follow the standard Debian package pattern. If a key differs on your release, apt falls back to interactive prompts; answer with the values the script prints.
- If another service on the same host renews certificates by stopping nginx, that renewal briefly drops all vhosts including this one. LiveSync resyncs automatically afterward.
- If you place this host behind a proxy with a request body cap, very large single documents can be rejected. LiveSync chunks data, so this is normally fine; keep the plugin chunk size moderate.
- The nginx vhost templates use the modern http2 directive (http2 on;). The installer detects the running nginx version and, on nginx older than 1.25.1 (for example Debian 12 which ships 1.22), automatically rewrites the vhost to the older listen-parameter form (listen 443 ssl http2;) so the config test passes. This also applies to the optional 444 drop vhost.

## Sources

- Obsidian LiveSync, setup own server (Install CouchDB directly, couchdb-init.sh): https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/setup_own_server.md
- Apache CouchDB, installation on Unix-like systems (Debian repo, admin required before start): https://docs.couchdb.org/en/stable/install/unix.html

## License

MIT. See LICENSE.
