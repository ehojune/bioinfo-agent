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
#
# IDENTIFY IT BY FINGERPRINT, NEVER BY NAME. The certificate offered here comes out of the
# very handshake that just failed verification — it is supplied by whoever is intercepting.
# Subject and issuer are free text that party chose, so "it says SOOSAN INT" proves nothing.
# The SHA256 fingerprint is the only field that identifies a certificate. Get the expected
# one from your organisation (or from the Windows machine store, where PowerShell's
# Thumbprint is the SHA1) and pass it as --expect-fp; this then aborts on any mismatch.
#
# Usage:
#   bash 06-tls-trust.sh                 # probe and report only
#   bash 06-tls-trust.sh --accept --expect-fp <SHA256>        # install, verified
#   bash 06-tls-trust.sh --accept        # install after an interactive confirmation
#   bash 06-tls-trust.sh --accept --expect-fp <SHA256> --ca /path/to/corp-ca.crt
set -uo pipefail

ACCEPT=0
CA_FILE=""
EXPECT_FP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --accept) ACCEPT=1 ;;
    --ca) CA_FILE="${2:-}"; shift ;;
    --expect-fp) EXPECT_FP="${2:-}"; shift ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
# Accept a fingerprint pasted in any of the forms the tools print it.
EXPECT_FP="$(printf '%s' "$EXPECT_FP" | tr -d ': \t' | tr 'a-f' 'A-F')"

# config/host.env — per-machine overrides, read before the default so the docker/pipeline
# user here is a genuine fallback. load_host_env always returns 0: an unquoted value there
# is skipped, never fatal.
HOST_ENV="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/config/host.env"
. "$(dirname "$0")/lib/host-env.sh"      # parses; never executes host.env
load_host_env "$HOST_ENV"

USER_NAME="${BIOINFO_USER:-ehojune}"
USER_HOME="$(getent passwd "$USER_NAME" 2>/dev/null | cut -d: -f6)"
[ -n "$USER_HOME" ] || USER_HOME="/home/$USER_NAME"
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
fi

# ---------------------------------------------------------------- identity of the CA
fp() { openssl x509 -in "$CA_FILE" -noout -fingerprint "-$1" 2>/dev/null | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F'; }
FP_SHA256="$(fp sha256)"
FP_SHA1="$(fp sha1)"
[ -n "$FP_SHA256" ] || { echo "[06-tls] $CA_FILE is not a readable certificate" >&2; exit 1; }

echo
echo "=== CA that would be trusted ==="
openssl x509 -in "$CA_FILE" -noout -issuer -subject -dates | sed 's/^/  /'
echo "  subject and issuer above are free text chosen by the signer. The lines below are not:"
echo "  SHA256 = $FP_SHA256"
echo "  SHA1   = $FP_SHA1   (this is what PowerShell calls Thumbprint)"

if [ -n "$EXPECT_FP" ]; then
  if [ "$EXPECT_FP" != "$FP_SHA256" ]; then
    echo
    echo "[06-tls] ABORT — fingerprint mismatch. Do not trust this certificate." >&2
    echo "  --expect-fp  $EXPECT_FP" >&2
    echo "  presented    $FP_SHA256" >&2
    exit 1
  fi
  echo "  MATCHES --expect-fp"
fi

if [ "$ACCEPT" -ne 1 ]; then
  cat <<MSG

[06-tls] REPORT ONLY. Nothing was installed.

Confirm the SHA256 above against what your organisation publishes. If you only have access to
the Windows machine store, its Thumbprint property is the SHA1:

  Get-ChildItem Cert:\LocalMachine\Root | Where-Object { \$_.Thumbprint -eq '$FP_SHA1' }

Matching on \$_.Subject instead would prove nothing — an interceptor picks its own subject.

If it checks out, re-run pinned to the fingerprint you just verified:

  bash 06-tls-trust.sh --accept --expect-fp $FP_SHA256
MSG
  exit 0
fi

# Checked here rather than at the first install step, so nobody types a confirmation only
# to be told to start again under sudo.
if [ "$(id -u)" -ne 0 ]; then
  echo
  echo "[06-tls] --accept writes to /usr/local/share/ca-certificates and the JVM cacerts; re-run with sudo." >&2
  exit 1
fi

# ---------------------------------------------------------------- unverified --accept
if [ -z "$EXPECT_FP" ]; then
  cat <<MSG

############################################################################
  NOTHING HAS BEEN CRYPTOGRAPHICALLY VERIFIED.

  This certificate came out of the handshake that failed verification, so it
  was supplied by whoever is intercepting. Nothing so far has checked that it
  is your organisation's appliance rather than an attacker's.

    SHA256  $FP_SHA256

  Installing it makes that party able to read this machine's TLS traffic,
  system-wide and JVM-wide, silently, for every tool on the box.

  Verify the fingerprint out of band, then re-run with
  --expect-fp $FP_SHA256
############################################################################

MSG
  if [ ! -t 0 ]; then
    echo "[06-tls] refusing to install unverified with no terminal to confirm at. Pass --expect-fp." >&2
    exit 1
  fi
  printf 'Type the last 8 characters of that SHA256 to install it anyway: '
  read -r ANSWER
  ANSWER="$(printf '%s' "$ANSWER" | tr -d ': \t' | tr 'a-f' 'A-F')"
  if [ "$ANSWER" != "${FP_SHA256: -8}" ]; then
    echo "[06-tls] no match — nothing installed." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- install into three stores
echo
echo "=== 1/3 system trust store ==="
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
# NOT ~/.config/bioinfo/env.sh: 03-nextflow.sh rewrites that file wholesale on every run,
# so anything appended there is gone at the next 03. env.local.sh is the sibling env.sh
# sources at its end precisely so machine-local additions survive.
ENVDIR="$USER_HOME/.config/bioinfo"
ENVLOCAL="$ENVDIR/env.local.sh"
mkdir -p "$ENVDIR"
if ! grep -q 'REQUESTS_CA_BUNDLE' "$ENVLOCAL" 2>/dev/null; then
  cat >> "$ENVLOCAL" <<'ENVEOF'
# written by bootstrap/06-tls-trust.sh — certifi and requests ignore the system store
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENVEOF
fi
chown -R "$USER_NAME":"$USER_NAME" "$ENVDIR" 2>/dev/null || true
chmod 0644 "$ENVLOCAL"

# PERSISTENCE IS PART OF THE VERDICT, not a footnote.
# The probe below runs with REQUESTS_CA_BUNDLE exported into this script's own environment,
# so it proves the CA bundle *works* — it cannot prove a future login shell will see it.
# That only holds if the file was written AND env.sh sources it. Both are checked here, and
# both count toward FAIL, because "OK" while nf-core still breaks tomorrow is the failure
# this script was written to stop.
PERSIST=0
if ! grep -q 'REQUESTS_CA_BUNDLE' "$ENVLOCAL" 2>/dev/null; then
  echo "  FAIL: could not write REQUESTS_CA_BUNDLE to $ENVLOCAL" >&2
  PERSIST=1
elif [ ! -f "$ENVDIR/env.sh" ]; then
  echo "  FAIL: $ENVDIR/env.sh does not exist, so nothing sources $ENVLOCAL." >&2
  echo "        Run bootstrap/03-nextflow.sh, then re-run this script." >&2
  PERSIST=1
elif ! grep -q 'env.local.sh' "$ENVDIR/env.sh"; then
  echo "  FAIL: $ENVDIR/env.sh predates the env.local.sh hook, so nothing sources $ENVLOCAL." >&2
  echo "        Re-run bootstrap/03-nextflow.sh, then re-run this script." >&2
  PERSIST=1
else
  echo "  REQUESTS_CA_BUNDLE / SSL_CERT_FILE written to $ENVLOCAL, sourced via env.sh"
fi

echo
echo "=== re-probing all three stores ==="
# The old version re-probed with curl only, so it printed OK while Python was untouched.
FAIL=$PERSIST
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

for url in $PROBES; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null)
  if [ "$code" = "000" ]; then echo "  curl    STILL FAILING  ${url#https://}"; FAIL=1
  else echo "  curl    ok             ${url#https://} -> $code"; fi
done

# One host is enough for the other two stores: they either trust the CA or they do not.
TARGET=$(echo "$BROKEN" | awk '{print $1}')
[ -n "$TARGET" ] || TARGET="get.nextflow.io"

if command -v python3 >/dev/null 2>&1; then
  if python3 - "$TARGET" <<'PY' 2>/dev/null
import sys
url = "https://" + sys.argv[1]
try:
    import requests                      # what nf-core actually uses; honours certifi
    requests.get(url, timeout=20)
except ImportError:
    import urllib.request
    urllib.request.urlopen(url, timeout=20).read(1)
PY
  then echo "  python  ok             $TARGET  (with the CA bundle exported; persistence checked above)"
  else echo "  python  STILL FAILING  $TARGET  — certifi/requests trust is not fixed"; FAIL=1; fi
else
  echo "  python  SKIPPED        python3 not installed (bootstrap/01-wsl-base.sh installs it)"
fi

# The JVM store has no probe here on purpose. A headless JRE ships no jshell, and the
# obvious substitutes exit 0 on a failed handshake — a false OK is worse than no check.
# keytool -list proves the import landed; the handshake is proven by the first real
# `nextflow pull`, which is the next thing you will run anyway.
if command -v keytool >/dev/null 2>&1 && \
   keytool -list -alias corp-tls-inspection -cacerts -storepass changeit >/dev/null 2>&1; then
  echo "  java    PRESENT        alias corp-tls-inspection is in the JVM cacerts (handshake unproven)"
else
  echo "  java    MISSING        alias corp-tls-inspection is NOT in the JVM cacerts — Nextflow will still fail"; FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "[06-tls] OK — every store probed above reached $TARGET. Lines marked SKIPPED or"
  echo "         'handshake unproven' are exactly that; confirm with a real nextflow pull."
else
  echo "[06-tls] some stores still failing"
  exit 1
fi
