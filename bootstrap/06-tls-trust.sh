#!/usr/bin/env bash
# 06-tls-trust.sh — detect a TLS-inspecting middlebox and, if you accept it, trust its CA.
#
# WHY THIS EXISTS
# Many institutional networks run an inspecting proxy that terminates TLS and re-signs traffic
# with a private CA. Windows browsers work because the CA is in the Windows trust store; a fresh
# WSL distro knows nothing about it. The failure looks like this:
#
#   curl: (60) SSL certificate problem: self-signed certificate in certificate chain
#
# It is often SELECTIVE — common domains are allowlisted and only less-trafficked ones are
# intercepted. On the machine this repo was built on, github.com and pypi.org were fine while
# get.nextflow.io was intercepted by "ePrism SSL" (SOOSAN INT). So "some downloads work" does
# not mean you are clear.
#
# THREE TRUST STORES, NOT ONE. This is the part people miss:
#   system  — curl, apt, git          (/usr/local/share/ca-certificates + update-ca-certificates)
#   Java    — Nextflow itself         (JVM cacerts; the JVM ignores the system store entirely)
#   Python  — nf-core tools           (certifi ships its own bundle; redirect it with env vars)
# Fixing only the system store gets you a working curl and a Nextflow that still cannot pull a
# pipeline. Fix all three.
#
# SAFETY
# Trusting an interception CA means that proxy can read this machine's TLS traffic. That is a
# real decision, so this script REPORTS by default and only installs when you pass --accept.
# Read the issuer it prints and make sure it is your organisation's appliance.
#
# Usage:
#   bash 06-tls-trust.sh                 # probe and report only
#   bash 06-tls-trust.sh --accept        # probe, then install the CA it found
#   bash 06-tls-trust.sh --accept --ca /path/to/corp-ca.crt   # install a CA you supply
set -uo pipefail

ACCEPT=0
CA_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --accept) ACCEPT=1 ;;
    --ca) CA_FILE="${2:-}"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

USER_NAME="${BIOINFO_USER:-ehojune}"
USER_HOME="/home/$USER_NAME"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Hosts this stack actually needs. get.nextflow.io and nf-co.re are the ones that tend to be
# intercepted, because they are not in any proxy's popular-domain allowlist.
PROBES="https://get.nextflow.io https://nf-co.re https://github.com https://pypi.org https://depot.galaxyproject.org https://community.wave.seqera.io"

echo "=== probing TLS ==="
BROKEN=""
for url in $PROBES; do
  host=${url#https://}
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>"$WORKDIR/err")
  if [ "$code" = "000" ] && grep -qi 'certificate' "$WORKDIR/err"; then
    echo "  INTERCEPTED  $host"
    BROKEN="$BROKEN $host"
  elif [ "$code" = "000" ]; then
    echo "  UNREACHABLE  $host  ($(tr -d '\n' < "$WORKDIR/err" | cut -c1-70))"
  else
    echo "  ok           $host -> $code"
  fi
done

if [ -z "$BROKEN" ] && [ -z "$CA_FILE" ]; then
  echo
  echo "[06-tls] no interception detected. Nothing to do."
  exit 0
fi

# ---------------------------------------------------------------- identify the CA
if [ -z "$CA_FILE" ]; then
  TARGET=$(echo "$BROKEN" | awk '{print $1}')
  echo
  echo "=== certificate chain presented for $TARGET ==="
  echo | openssl s_client -connect "$TARGET:443" -servername "$TARGET" -showcerts 2>/dev/null \
    > "$WORKDIR/chain.txt"
  grep -E '^ *[0-9]+ s:|^ *i:' "$WORKDIR/chain.txt" | sed 's/^/  /'

  # The injected root is the last certificate in the presented chain.
  awk '/-----BEGIN CERTIFICATE-----/{n++} n>0{print > "'"$WORKDIR"'/cert-" n ".pem"}' "$WORKDIR/chain.txt"
  LAST=$(ls -1 "$WORKDIR"/cert-*.pem 2>/dev/null | sort -V | tail -1)
  if [ -z "$LAST" ]; then
    echo "[06-tls] could not extract a certificate from the handshake. Supply one with --ca." >&2
    exit 1
  fi
  CA_FILE="$LAST"
  echo
  echo "=== CA that would be trusted ==="
  openssl x509 -in "$CA_FILE" -noout -issuer -subject -dates | sed 's/^/  /'
fi

if [ "$ACCEPT" -ne 1 ]; then
  cat <<'MSG'

[06-tls] REPORT ONLY. Nothing was installed.

Check the issuer above against what your organisation says it runs. On Windows you can confirm
it is already trusted there:

  Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match '<issuer CN>' }

If it matches, re-run with --accept.
MSG
  exit 0
fi

# ---------------------------------------------------------------- install into three stores
echo
echo "=== 1/3 system trust store ==="
if [ "$(id -u)" -ne 0 ]; then echo "  needs root; re-run with sudo" >&2; exit 1; fi
install -m 644 "$CA_FILE" /usr/local/share/ca-certificates/corp-tls-inspection.crt
update-ca-certificates 2>&1 | sed 's/^/  /' | tail -2

echo "=== 2/3 java cacerts (Nextflow is a JVM app and ignores the system store) ==="
if command -v keytool >/dev/null 2>&1; then
  keytool -delete -alias corp-tls-inspection -cacerts -storepass changeit >/dev/null 2>&1 || true
  keytool -importcert -alias corp-tls-inspection -cacerts -storepass changeit -noprompt \
          -file "$CA_FILE" 2>&1 | sed 's/^/  /' | tail -1
else
  echo "  keytool not found — install a JDK/JRE first (bootstrap/01-wsl-base.sh)" >&2
fi

echo "=== 3/3 python (certifi ships its own bundle) ==="
ENVFILE="$USER_HOME/.bioinfo.env"
if [ -f "$ENVFILE" ]; then
  grep -q 'REQUESTS_CA_BUNDLE' "$ENVFILE" || cat >> "$ENVFILE" <<'ENVEOF'
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENVEOF
  echo "  REQUESTS_CA_BUNDLE / SSL_CERT_FILE set in $ENVFILE"
else
  echo "  $ENVFILE missing — run bootstrap/03-nextflow.sh first" >&2
fi

echo
echo "=== re-probing ==="
FAIL=0
for url in $PROBES; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null)
  if [ "$code" = "000" ]; then echo "  STILL FAILING  ${url#https://}"; FAIL=1
  else echo "  ok             ${url#https://} -> $code"; fi
done

[ "$FAIL" -eq 0 ] && echo "[06-tls] OK" || { echo "[06-tls] some hosts still failing"; exit 1; }
