#!/bin/bash
# Creates the stable codesigning identity "Bud Development", once.
#
# Bud is signed ad-hoc by default, and an ad-hoc signature is a different code
# identity for every build — so macOS treats every release as a new application
# and re-prompts for Keychain access to Bud's secrets after each update. A
# self-signed identity, created once and reused by build-app.sh for every
# release, keeps the designated requirement stable across updates: the prompts
# happen once, when the identity is first used, and never again.
#
# Idempotent: run it again and it reports the existing identity and exits.
# A stale untrusted identity with the same name is removed first, so codesign
# never faces two candidates for one name.
#
# The certificate is trusted for code signing on this machine only — which is
# exactly what a locally built and locally updated app needs, and nothing more.
set -euo pipefail

NAME="Bud Development"

# A valid identity is the whole job; report it and leave.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "identity '$NAME' already exists:"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

# An untrusted one with the same name would make `codesign --sign "$NAME"`
# ambiguous. Drop it before making a fresh one.
security find-identity -p codesigning 2>/dev/null \
  | awk -F'"' -v name="$NAME" '$2 == name { print $1 }' \
  | awk '{ print $NF }' \
  | while read -r hash; do
      security delete-identity -Z "$hash" >/dev/null 2>&1 || true
    done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating a self-signed codesigning certificate"
openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
openssl req -new -x509 -key "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=Bud Development/O=Bud/OU=Code Signing" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" 2>/dev/null

echo "==> Trusting it for code signing (before import — trust first is what makes it valid)"
openssl x509 -in "$TMP/cert.pem" -inform PEM -out "$TMP/cert.der" -outform DER
security add-trusted-cert -d -r trustRoot \
  -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.der"

echo "==> Importing the key pair into the login keychain"
# The legacy PBEs are deliberate: OpenSSL 3's default PKCS#12 encryption is
# not understood by `security import`.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:bud \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
security import "$TMP/identity.p12" -P bud \
  -T /usr/bin/codesign -T /usr/bin/security

echo "==> Identity ready:"
security find-identity -v -p codesigning | grep "$NAME"
echo "build-app.sh will now sign every release with it."
