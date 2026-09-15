#!/bin/bash
# Generates the Ed25519 keypair that signs Bud's update feed.
#
# Why regeneration is guarded: the signing key is the root of trust for every
# update a user has already installed. Silently replacing it would leave every
# shipped build unable to verify the next release, so overwriting requires an
# explicit --force, and the private half is never printed.
#
# The private key is stored as the raw 32-byte Ed25519 seed rather than as PEM:
# it is the smallest secret we can keep on disk, and the PKCS#8 wrapper openssl
# wants is rebuilt on demand (see pem_from_seed below, mirrored in
# bud-release.sh). That keeps the release path independent of the Python
# `cryptography` package, which is not installed everywhere Bud is built.
set -euo pipefail

KEY_DIR="$HOME/.bud/keys"
KEY="$KEY_DIR/update-signing.key"
FORCE=0

usage() {
  cat <<USAGE
usage: $(basename "$0") [--force]

  --force   replace an existing signing key. Every build already signed with
            the old key stops being updatable, so this is opt-in only.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -e "$KEY" && "$FORCE" -ne 1 ]]; then
  echo "error: a signing key already exists at $KEY" >&2
  echo "error: refusing to overwrite it — no build signed with the old key could ever verify again" >&2
  echo "error: re-run with --force only if you accept re-signing every shipped release" >&2
  exit 1
fi

# Secrets are created under a private umask so the key never exists, even
# briefly, with permissions beyond its owner's.
umask 077

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Rebuild the PKCS#8 PEM openssl needs from the raw seed. The hex prefix is the
# fixed Ed25519 AlgorithmIdentifier plus an OCTET STRING header for a 32-byte
# key; nothing here is key-dependent.
pem_from_seed() {
  local seed="$1" dest="$2" hex b64
  hex="$(xxd -p -c 64 "$seed")"
  if [[ ! "$hex" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: signing seed must be exactly 32 bytes" >&2
    exit 1
  fi
  b64="$(printf '302e020100300506032b657004220420%s' "$hex" | xxd -r -p | openssl base64 -A)"
  {
    echo "-----BEGIN PRIVATE KEY-----"
    printf '%s\n' "$b64" | fold -w 64
    echo "-----END PRIVATE KEY-----"
  } > "$dest"
}

# Wrap raw key bytes (32 of them) in the SubjectPublicKeyInfo PEM openssl
# verifies against.
pub_pem_from_raw() {
  local raw_hex="$1" dest="$2" b64
  b64="$(printf '302a300506032b6570032100%s' "$raw_hex" | xxd -r -p | openssl base64 -A)"
  {
    echo "-----BEGIN PUBLIC KEY-----"
    printf '%s\n' "$b64" | fold -w 64
    echo "-----END PUBLIC KEY-----"
  } > "$dest"
}

echo "==> Creating $KEY_DIR (0700)"
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

echo "==> Generating Ed25519 seed"
openssl rand 32 > "$TMP/seed"
pem_from_seed "$TMP/seed" "$TMP/key.pem"

# The reconstructed PEM is about to become the only copy of a key nobody can
# re-derive, so prove openssl reads it as an Ed25519 private key first.
if ! openssl pkey -in "$TMP/key.pem" -noout -text > "$TMP/key.txt" 2>"$TMP/key.err"; then
  echo "error: reconstructed key is not a usable private key" >&2
  cat "$TMP/key.err" >&2
  exit 1
fi
if ! grep -q 'ED25519' "$TMP/key.txt"; then
  echo "error: reconstructed key is not Ed25519" >&2
  exit 1
fi

echo "==> Writing $KEY (0600)"
# Remove first: a pre-existing file (from --force) would keep its own mode and
# owner, and we would be writing the new seed into it unchecked.
rm -f "$KEY"
cat "$TMP/seed" > "$KEY"
chmod 600 "$KEY"

perms="$(stat -f %Lp "$KEY")"
if [[ "$perms" != "600" ]]; then
  echo "error: $KEY ended up mode $perms, expected 600" >&2
  exit 1
fi
bytes="$(stat -f%z "$KEY")"
if [[ "$bytes" != "32" ]]; then
  echo "error: $KEY is $bytes bytes, expected a 32-byte seed" >&2
  exit 1
fi

# Derive the public half. The DER layout is fixed, so we can both check it and
# take the key out of it by known offsets.
openssl pkey -in "$TMP/key.pem" -pubout -outform DER > "$TMP/pub.der"
pub_hex="$(xxd -p -c 64 "$TMP/pub.der")"
if [[ ! "$pub_hex" =~ ^302a300506032b6570032100[0-9a-f]{64}$ ]]; then
  echo "error: unexpected public key encoding: $pub_hex" >&2
  exit 1
fi
pub_raw_hex="${pub_hex:24:64}"
pub_b64="$(printf '%s' "$pub_raw_hex" | xxd -r -p | openssl base64 -A)"
pub_pem_from_raw "$pub_raw_hex" "$TMP/pub.pem"

# Round-trip the pair we are about to hand out: sign with the stored seed,
# verify with the raw public key we print. A mistake in the PEM wrapping or the
# DER offset would surface here instead of at release time, when the key is the
# only copy left.
echo "bud-update-keygen self-test" > "$TMP/probe"
openssl pkeyutl -sign -rawin -inkey "$TMP/key.pem" -in "$TMP/probe" -out "$TMP/probe.sig"
if ! openssl pkeyutl -verify -rawin -pubin -inkey "$TMP/pub.pem" -in "$TMP/probe" -sigfile "$TMP/probe.sig" >/dev/null 2>&1; then
  echo "error: generated keypair failed its own sign/verify self-test" >&2
  exit 1
fi

echo "==> Public key (base64, 32 bytes) — embed this in the Swift updater:"
echo "$pub_b64"
echo "warning: losing $KEY means no future release can be signed; it must never be committed."
