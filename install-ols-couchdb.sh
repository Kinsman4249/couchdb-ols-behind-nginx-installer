#!/usr/bin/env bash
#
# install-ols-couchdb.sh
# Native (no-Docker) CouchDB backend for Obsidian Self-hosted LiveSync on
# Debian, fronted by an existing nginx via an SNI vhost.
#
# Generic: every hostname, credential, token, path, and the TLS method are
# prompted for at runtime. Nothing is hardcoded.
#
# Sources:
#   Maintainer "Install CouchDB directly" + couchdb-init.sh:
#     https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/setup_own_server.md
#   Apache CouchDB Debian install (admin required before start):
#     https://docs.couchdb.org/en/stable/install/unix.html
#
# Prompts are plain (echoed) on purpose. Write the values down.
#
set -euo pipefail

# --- Re-exec as root ------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "Not root. Re-executing under sudo..."
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- nginx version / http2 syntax compatibility --------------------------
# nginx 1.25.1 introduced the standalone "http2 on;" directive. Older nginx
# (for example Debian 12 ships 1.22) rejects it with: unknown directive "http2".
# The shipped vhost templates use the modern syntax; normalize_http2() rewrites
# a rendered vhost to the older "listen ... ssl http2;" form when the detected
# nginx is older, so the config test passes on both.
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
NGINX_VER="$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9][0-9.]*\).*#\1#p' || true)"
if [ -n "${NGINX_VER}" ] && version_ge "${NGINX_VER}" "1.25.1"; then
  HTTP2_MODERN=1
else
  HTTP2_MODERN=0
fi
normalize_http2() {
  local f="$1"
  [ "${HTTP2_MODERN}" -eq 1 ] && return 0
  sed -i \
    -e 's/^\(\s*\)listen \(\[::\]:\)\{0,1\}443 ssl\( default_server\)\{0,1\};/\1listen \2443 ssl\3 http2;/' \
    -e '/^[[:space:]]*http2 on;/d' \
    "$f"
}

echo "============================================================"
echo "  CouchDB + Obsidian Self-hosted LiveSync installer"
echo "============================================================"
echo "All values are prompted. Nothing is hardcoded."
echo "Detected nginx version: ${NGINX_VER:-unknown} (modern http2 syntax: $([ "${HTTP2_MODERN}" -eq 1 ] && echo yes || echo no))"
echo

# --- Hostname (required, no default) --------------------------------------
DOMAIN=""
while [ -z "${DOMAIN}" ]; do
  read -r -p "Public hostname for the sync server (e.g. notes.example.com): " DOMAIN
done
DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')"

# --- CouchDB admin password -----------------------------------------------
# NOTE: the CouchDB Debian package always creates an admin account literally
# named "admin". debconf only lets us set that account's PASSWORD, not its
# name. So this password belongs to the "admin" user. If you want an
# additional admin under a different name, answer the later prompt.
echo
echo "The CouchDB Debian package creates a server admin named 'admin'."
echo "Set that admin's password now."
CDB_PASS=""
while [ -z "${CDB_PASS}" ]; do
  read -r -p "CouchDB 'admin' password: " CDB_PASS
done

read -r -p "Vault database name for the plugin [obsidiannotes]: " CDB_DB
CDB_DB="${CDB_DB:-obsidiannotes}"

# Optional: an additional admin account under a name you choose.
echo
echo "Optionally create an ADDITIONAL admin account under a name of your"
echo "choice (same password as above). Leave blank to use only 'admin'."
read -r -p "Extra admin username (blank for none): " EXTRA_ADMIN

# --- Optional extra nginx includes ---------------------------------------
echo
echo "If you have existing nginx include files to apply inside this vhost"
echo "(for example an origin lockdown, real-ip, or mTLS snippet), enter their"
echo "full paths separated by spaces. Leave blank for none."
read -r -p "Extra include file paths: " EXTRA_INCLUDES_RAW

EXTRA_INCLUDES_BLOCK=""
if [ -n "${EXTRA_INCLUDES_RAW}" ]; then
  for inc in ${EXTRA_INCLUDES_RAW}; do
    EXTRA_INCLUDES_BLOCK+="    include ${inc};"$'\n'
  done
fi

# --- TLS method -----------------------------------------------------------
echo
echo "TLS certificate options:"
echo "  1) certbot DNS-01 plugin (recommended behind a proxy/firewall)"
echo "  2) certbot webroot (HTTP-01)"
echo "  3) certbot standalone (HTTP-01, needs port 80 free)"
echo "  4) I already have a certificate (provide paths)"
echo "  5) Skip for now (write vhost, do not enable)"
read -r -p "Choose [1-5]: " TLS_CHOICE
TLS_CHOICE="${TLS_CHOICE:-5}"

SSL_CERT=""
SSL_KEY=""

case "${TLS_CHOICE}" in
  1)
    echo "certbot DNS-01. Provider bits are prompted so any provider works."
    read -r -p "certbot DNS plugin apt package (e.g. python3-certbot-dns-cloudflare): " DNS_PKG
    read -r -p "certbot authenticator name (e.g. dns-cloudflare): " DNS_AUTH
    read -r -p "Path to certbot DNS credentials file: " DNS_CREDS
    read -r -p "Email for Let's Encrypt registration: " LE_EMAIL
    if [ ! -f "${DNS_CREDS}" ]; then
      echo "Credentials file not found. Enter its contents now."
      echo "Example for Cloudflare: dns_cloudflare_api_token = YOUR_TOKEN"
      echo "Finish by entering a single line containing only: EOF"
      install -d -m 700 "$(dirname "${DNS_CREDS}")"
      : > "${DNS_CREDS}"
      while IFS= read -r line; do
        [ "${line}" = "EOF" ] && break
        printf '%s\n' "${line}" >> "${DNS_CREDS}"
      done
    fi
    chmod 600 "${DNS_CREDS}"
    apt-get update
    apt-get install -y certbot "${DNS_PKG}"
    certbot certonly --authenticator "${DNS_AUTH}" \
      "--${DNS_AUTH}-credentials" "${DNS_CREDS}" \
      -d "${DOMAIN}" --non-interactive --agree-tos -m "${LE_EMAIL}" \
      --deploy-hook "systemctl reload nginx"
    SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    ;;
  2)
    read -r -p "Webroot path for the HTTP-01 challenge (e.g. /var/www/html): " WEBROOT
    read -r -p "Email for Let's Encrypt registration: " LE_EMAIL
    apt-get update
    apt-get install -y certbot
    certbot certonly --webroot -w "${WEBROOT}" -d "${DOMAIN}" \
      --non-interactive --agree-tos -m "${LE_EMAIL}" \
      --deploy-hook "systemctl reload nginx"
    SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    ;;
  3)
    read -r -p "Email for Let's Encrypt registration: " LE_EMAIL
    apt-get update
    apt-get install -y certbot
    echo "standalone needs port 80 free; certbot will bind it briefly."
    certbot certonly --standalone -d "${DOMAIN}" \
      --non-interactive --agree-tos -m "${LE_EMAIL}" \
      --deploy-hook "systemctl reload nginx"
    SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    ;;
  4)
    read -r -p "Full path to the certificate (fullchain) file: " SSL_CERT
    read -r -p "Full path to the private key file: " SSL_KEY
    ;;
  *)
    echo "Skipping certificate acquisition."
    SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    ;;
esac

# Random Erlang cluster cookie. Recorded in the summary; rarely needed again.
CDB_COOKIE="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"

BIND_ADDR="127.0.0.1"   # localhost only; nginx is the sole public door.
PORT="5984"
ADMIN_USER="admin"      # fixed by the CouchDB Debian package; not configurable.

# ==========================================================================
# 1. Apache CouchDB repository (Debian)
# ==========================================================================
apt-get update
apt-get install -y curl apt-transport-https gnupg lsb-release ca-certificates
curl https://couchdb.apache.org/repo/keys.asc \
  | gpg --dearmor \
  | tee /usr/share/keyrings/couchdb-archive-keyring.gpg >/dev/null 2>&1
# shellcheck disable=SC1091
source /etc/os-release
echo "deb [signed-by=/usr/share/keyrings/couchdb-archive-keyring.gpg] https://apache.jfrog.io/artifactory/couchdb-deb/ ${VERSION_CODENAME} main" \
  | tee /etc/apt/sources.list.d/couchdb.list >/dev/null

# ==========================================================================
# 2. Pre-seed debconf: standalone, localhost-bound, admin password set.
#    The admin account name is always "admin" (package default); debconf has
#    no field for the admin username. If a key differs on your release, apt
#    falls back to prompting; answer with the printed values.
# ==========================================================================
apt-get update
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<EOF
couchdb couchdb/mode select standalone
couchdb couchdb/bindaddress string ${BIND_ADDR}
couchdb couchdb/cookie string ${CDB_COOKIE}
couchdb couchdb/adminpass password ${CDB_PASS}
couchdb couchdb/adminpass_again password ${CDB_PASS}
EOF

# ==========================================================================
# 3. Install CouchDB
# ==========================================================================
apt-get install -y couchdb
sleep 3
systemctl enable --now couchdb 2>/dev/null || true
sleep 3

echo "--- Sockets on :${PORT} (must be ${BIND_ADDR}, not 0.0.0.0) ---"
ss -tlnp | grep ":${PORT}" || true

echo "--- Auth check (as ${ADMIN_USER}) ---"
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "http://${ADMIN_USER}:${CDB_PASS}@${BIND_ADDR}:${PORT}/_node/_local/_config/admins" || true

# ==========================================================================
# 4. Maintainer init script (CORS, Obsidian origins, require_valid_user...).
#    Authenticate as "admin". This account is guaranteed to exist; using a
#    non-existent username here causes every config PUT to 401 silently, which
#    leaves the plugin reporting all settings as wrong.
# ==========================================================================
export hostname="${BIND_ADDR}:${PORT}"
export username="${ADMIN_USER}"
export password="${CDB_PASS}"
curl -s https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/main/utils/couchdb/couchdb-init.sh | bash

# ==========================================================================
# 5. Optionally create an additional admin under the chosen name.
# ==========================================================================
if [ -n "${EXTRA_ADMIN}" ]; then
  echo "Creating additional admin '${EXTRA_ADMIN}'..."
  curl -s -o /dev/null -w "create admin ${EXTRA_ADMIN}: HTTP %{http_code}\n" \
    -X PUT "http://${ADMIN_USER}:${CDB_PASS}@${BIND_ADDR}:${PORT}/_node/_local/_config/admins/${EXTRA_ADMIN}" \
    --data-raw "\"${CDB_PASS}\"" || true
fi

# ==========================================================================
# 6. Create the vault database (as admin).
# ==========================================================================
curl -s -o /dev/null -w "create db ${CDB_DB}: HTTP %{http_code}\n" \
  -X PUT "http://${ADMIN_USER}:${CDB_PASS}@${BIND_ADDR}:${PORT}/${CDB_DB}" || true

# ==========================================================================
# 7. nginx: rate-limit fragment + rendered SNI vhost.
# ==========================================================================
NGX_CONFD="/etc/nginx/conf.d"
NGX_AVAIL="/etc/nginx/sites-available"
NGX_ENABL="/etc/nginx/sites-enabled"

install -m 0644 "${SCRIPT_DIR}/nginx/obsidian-livesync-ratelimit.conf" \
  "${NGX_CONFD}/obsidian-livesync-ratelimit.conf"

awk -v d="${DOMAIN}" -v c="${SSL_CERT}" -v k="${SSL_KEY}" \
    -v inc="${EXTRA_INCLUDES_BLOCK}" '
{
  gsub(/@@DOMAIN@@/, d)
  gsub(/@@SSL_CERT@@/, c)
  gsub(/@@SSL_KEY@@/, k)
  if ($0 ~ /@@EXTRA_INCLUDES@@/) { printf "%s", inc; next }
  print
}' "${SCRIPT_DIR}/nginx/obsidian-livesync.conf" > "${NGX_AVAIL}/obsidian-livesync"

# Rewrite http2 syntax for older nginx if needed.
normalize_http2 "${NGX_AVAIL}/obsidian-livesync"

# ==========================================================================
# 8. Enable the vhost only if the cert and key exist.
# ==========================================================================
if [ -f "${SSL_CERT}" ] && [ -f "${SSL_KEY}" ]; then
  ln -sf "${NGX_AVAIL}/obsidian-livesync" "${NGX_ENABL}/obsidian-livesync"
  if nginx -t; then
    systemctl reload nginx
    echo "nginx vhost enabled and reloaded."
  else
    echo "nginx -t failed. vhost left symlinked; fix and reload manually."
  fi
else
  echo "Certificate or key not found at:"
  echo "  ${SSL_CERT}"
  echo "  ${SSL_KEY}"
  echo "vhost written to ${NGX_AVAIL}/obsidian-livesync but NOT enabled."
  echo "Once the cert exists: ln -sf ${NGX_AVAIL}/obsidian-livesync ${NGX_ENABL}/ && nginx -t && systemctl reload nginx"
fi

# ==========================================================================
# 9. Optional 444 default_server drop for unknown SNI / raw-IP on 443.
# ==========================================================================
read -r -p "Install 444 default_server drop for unknown SNI? [y/N]: " DO_DROP
DO_DROP="${DO_DROP:-N}"
if [[ "${DO_DROP}" =~ ^[Yy] ]]; then
  apt-get install -y ssl-cert
  install -m 0644 "${SCRIPT_DIR}/nginx/00-tls-default-drop.conf" \
    "${NGX_AVAIL}/00-tls-default-drop"
  normalize_http2 "${NGX_AVAIL}/00-tls-default-drop"
  ln -sf "${NGX_AVAIL}/00-tls-default-drop" "${NGX_ENABL}/00-tls-default-drop"
  nginx -t && systemctl reload nginx || \
    echo "nginx -t failed after adding drop vhost; review it."
fi

# ==========================================================================
# 10. Summary. WRITE THESE DOWN.
# ==========================================================================
PLUGIN_USER="${ADMIN_USER}"
[ -n "${EXTRA_ADMIN}" ] && PLUGIN_USER="${ADMIN_USER} (or ${EXTRA_ADMIN})"
cat <<SUMMARY

============================================================
  WRITE THESE DOWN
============================================================
  Sync URL (plugin) : https://${DOMAIN}
  CouchDB admin user: ${ADMIN_USER}   (fixed by the Debian package)
  CouchDB admin pass: ${CDB_PASS}
  Extra admin user  : ${EXTRA_ADMIN:-<none>}
  Vault DB name     : ${CDB_DB}
  Bind address      : ${BIND_ADDR}:${PORT}  (localhost only)
  Erlang cookie     : ${CDB_COOKIE}

  Obsidian Self-hosted LiveSync plugin:
    URI      : https://${DOMAIN}
    Username : ${PLUGIN_USER}
    Password : ${CDB_PASS}
    Database : ${CDB_DB}
  Set an End-to-End encryption passphrase in the plugin. The server
  never sees it. Record it here: ____________________________
============================================================
SUMMARY
