#!/bin/bash
# Builds, packages and signs a Bud release, then writes the appcast the updater
# reads.
#
# Why the manifest exists: the updater has to decide, unaided, whether a newer
# Bud exists and whether the bytes it just downloaded are the ones we
# published. The appcast carries that decision — version, build, minimum OS,
# URL, size and sha256 — and the Ed25519 signature over the canonical string is
# what makes any of it trustworthy. The signature covers notes_sha256 as well,
# because the notes are rendered verbatim in the update prompt: without that
# binding, whoever serves the feed could put arbitrary text in front of the
# user. Hashing keeps the signed string line-oriented, which notes containing
# newlines would otherwise break.
#
# Version and build are stamped by build-app.sh rather than patched into the
# assembled bundle afterwards, so the plist, the binary's ad-hoc signature and
# the appcast all describe one build.
#
# Signing does not depend on the Python `cryptography` package: the private key
# is a raw 32-byte Ed25519 seed, and the PKCS#8 wrapper openssl wants is rebuilt
# around it here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Bud"
ZIP_NAME_BASE="Bud"
KEY="$HOME/.bud/keys/update-signing.key"

VERSION=""
BUILD_NUMBER=""
NOTES_FILE=""
CHANNEL="stable"
OUT="build/release"
PUBLISH=0

usage() {
  cat <<USAGE
usage: $(basename "$0") --version X.Y.Z --build N [options]

  --version X.Y.Z          version being released (required)
  --build N                build number being released (required)
  --notes FILE             release notes, shown to the user in the update
                           prompt (default: a one-line summary)
  --channel stable|prerelease
                           update channel to publish to (default: stable)
  --out DIR                where the zip and appcast go (default: build/release)
  --publish                create the GitHub release and upload both assets
USAGE
}

require_value() {
  # $1 = flag being parsed, $2 = number of remaining arguments
  if [[ "$2" -lt 2 ]]; then
    echo "error: $1 needs a value" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      require_value "$1" "$#"
      VERSION="$2"
      shift 2
      ;;
    --build)
      require_value "$1" "$#"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --notes)
      require_value "$1" "$#"
      NOTES_FILE="$2"
      shift 2
      ;;
    --channel)
      require_value "$1" "$#"
      CHANNEL="$2"
      shift 2
      ;;
    --out)
      require_value "$1" "$#"
      OUT="$2"
      shift 2
      ;;
    --publish)
      PUBLISH=1
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

if [[ -z "$VERSION" ]]; then
  echo "error: --version is required" >&2
  usage >&2
  exit 1
fi
if [[ -z "$BUILD_NUMBER" ]]; then
  echo "error: --build is required" >&2
  usage >&2
  exit 1
fi

# The updater compares these against the appcast, so a malformed value ships an
# unreleasable build. Reject it before anything expensive happens.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: --version must be X.Y.Z (got: $VERSION)" >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "error: --build must be an integer (got: $BUILD_NUMBER)" >&2
  exit 1
fi
if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "prerelease" ]]; then
  echo "error: --channel must be stable or prerelease (got: $CHANNEL)" >&2
  exit 1
fi

# No restrictive umask here on purpose: the zip and appcast are distributed
# artifacts and must keep ordinary modes (the app inside them is what another
# machine will unpack). The one secret we handle is copied into a temp
# directory, and mktemp -d already creates that 0700.
umask 022
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Notes as a string. Command substitution drops any trailing newline, which is
# what makes "the notes string" unambiguous between the JSON we write and the
# hash we sign.
if [[ -n "$NOTES_FILE" ]]; then
  if [[ ! -f "$NOTES_FILE" ]]; then
    echo "error: notes file not found: $NOTES_FILE" >&2
    exit 1
  fi
  NOTES="$(cat "$NOTES_FILE")"
  if [[ -z "$NOTES" ]]; then
    echo "error: notes file is empty: $NOTES_FILE" >&2
    exit 1
  fi
else
  NOTES="Bud $VERSION."
fi

# JSON strings, not JSON files: the notes are escaped for transport and hashed
# in their decoded form, so the escaper must not be allowed to lose anything.
# Control characters JSON cannot express as the escapes above have no place in
# release notes, so they fail loudly rather than being silently mangled. The
# check is byte-oriented (LC_ALL=C) and deletes the whitespace the escaper
# handles first, so UTF-8 notes pass — only real control bytes are rejected.
if printf '%s' "$NOTES" | LC_ALL=C tr -d '\n\r\t\v\f' | LC_ALL=C grep -q '[[:cntrl:]]'; then
  echo "error: notes contain a control character, which cannot be signed faithfully" >&2
  exit 1
fi

json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\v'/\\u000b}"
  s="${s//$'\f'/\\u000c}"
  printf '%s' "$s"
}

# Refuse to sign before spending a build on a release that cannot be signed.
if [[ ! -f "$KEY" ]]; then
  echo "error: no signing key at $KEY" >&2
  echo "error: create one with Scripts/bud-update-keygen.sh" >&2
  exit 1
fi
key_perms="$(stat -f %Lp "$KEY")"
if [[ "$key_perms" != "600" && "$key_perms" != "400" ]]; then
  echo "error: $KEY is mode $key_perms, which lets more than its owner read it" >&2
  echo "error: anyone who can read the key can sign releases; fix with:" >&2
  echo "error:   chmod 600 \"$KEY\"" >&2
  exit 1
fi
key_bytes="$(stat -f%z "$KEY")"
if [[ "$key_bytes" != "32" ]]; then
  echo "error: $KEY is $key_bytes bytes, expected a 32-byte Ed25519 seed" >&2
  echo "error: regenerate it with Scripts/bud-update-keygen.sh --force" >&2
  exit 1
fi

# Rebuild the PKCS#8 PEM openssl needs from the raw seed. The hex prefix is the
# fixed Ed25519 AlgorithmIdentifier plus an OCTET STRING header for a 32-byte
# key; nothing here is key-dependent. Mirrored in bud-update-keygen.sh, which
# deliberately owns no shared library so each script stands alone.
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

pub_pem_from_raw() {
  local raw_hex="$1" dest="$2" b64
  b64="$(printf '302a300506032b6570032100%s' "$raw_hex" | xxd -r -p | openssl base64 -A)"
  {
    echo "-----BEGIN PUBLIC KEY-----"
    printf '%s\n' "$b64" | fold -w 64
    echo "-----END PUBLIC KEY-----"
  } > "$dest"
}

# Where the release will live. Derived from the checkout rather than hardcoded
# so a fork cannot silently publish URLs pointing at the wrong repository.
REPO=""
if REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null)"; then
  REPO="$(printf '%s' "$REMOTE" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
fi
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "error: cannot determine the GitHub repository from 'git remote get-url origin' (got: ${REPO:-<none>})" >&2
  exit 1
fi

echo "==> Building $APP_NAME $VERSION (build $BUILD_NUMBER)"
"$ROOT/Scripts/build-app.sh" release --version "$VERSION" --build "$BUILD_NUMBER"

APP="$ROOT/build/$APP_NAME.app"
PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  echo "error: built bundle has no Info.plist at $PLIST" >&2
  exit 1
fi

# Read the stamping back out of the bundle we are about to ship: the zip, not
# this script's arguments, is what the updater installs, and the two must agree.
built_version="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
built_build="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
if [[ "$built_version" != "$VERSION" || "$built_build" != "$BUILD_NUMBER" ]]; then
  echo "error: bundle is stamped $built_version (build $built_build), expected $VERSION (build $BUILD_NUMBER)" >&2
  exit 1
fi
MIN_OS="$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")"
if [[ -z "$MIN_OS" ]]; then
  echo "error: bundle declares no LSMinimumSystemVersion, so the appcast cannot state one" >&2
  exit 1
fi

if [[ "$OUT" != /* ]]; then
  OUT="$ROOT/$OUT"
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

ZIP_NAME="Bud-$VERSION.zip"
ZIP="$OUT/$ZIP_NAME"
echo "==> Zipping $ZIP_NAME"
# A stale zip in the output directory would be signed as if it were this build.
rm -f "$ZIP"
# --keepParent preserves the enclosing Bud.app directory, which is what makes
# the archive installable by unpacking in place.
( cd "$ROOT/build" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ZIP" )
if [[ ! -f "$ZIP" ]]; then
  echo "error: ditto produced no archive at $ZIP" >&2
  exit 1
fi

SIZE="$(stat -f%z "$ZIP")"
SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: unexpected sha256 for $ZIP: $SHA256" >&2
  exit 1
fi
NOTES_SHA256="$(printf '%s' "$NOTES" | shasum -a 256 | awk '{print $1}')"
PUBLISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
URL="https://github.com/$REPO/releases/download/v$VERSION/$ZIP_NAME"

# The signed string: versioned by its first line so a future format can be
# rejected rather than misread, and byte-exact — no trailing newline, fixed
# field order. The updater rebuilds exactly this from the appcast it was given,
# so any field an attacker edits stops verifying.
printf 'bud-update-v1\nbuild=%s\nversion=%s\nchannel=%s\nminOS=%s\nurl=%s\nsize=%s\nsha256=%s\nnotes_sha256=%s' \
  "$BUILD_NUMBER" "$VERSION" "$CHANNEL" "$MIN_OS" "$URL" "$SIZE" "$SHA256" "$NOTES_SHA256" > "$TMP/canonical.txt"

pem_from_seed "$KEY" "$TMP/key.pem"

echo "==> Signing appcast (Ed25519)"
openssl pkeyutl -sign -rawin -inkey "$TMP/key.pem" -in "$TMP/canonical.txt" -out "$TMP/signature.bin"
sig_bytes="$(stat -f%z "$TMP/signature.bin")"
if [[ "$sig_bytes" != "64" ]]; then
  echo "error: signature is $sig_bytes bytes, expected 64" >&2
  exit 1
fi
SIGNATURE="$(openssl base64 -A -in "$TMP/signature.bin")"

# Verify against the public half before publishing anything: a signature that
# does not verify is a release no client can install, and the only cheap moment
# to find that out is now.
openssl pkey -in "$TMP/key.pem" -pubout -outform DER > "$TMP/pub.der"
pub_hex="$(xxd -p -c 64 "$TMP/pub.der")"
if [[ ! "$pub_hex" =~ ^302a300506032b6570032100[0-9a-f]{64}$ ]]; then
  echo "error: unexpected public key encoding: $pub_hex" >&2
  exit 1
fi
PUB_B64="$(printf '%s' "${pub_hex:24:64}" | xxd -r -p | openssl base64 -A)"
pub_pem_from_raw "${pub_hex:24:64}" "$TMP/pub.pem"
if ! openssl pkeyutl -verify -rawin -pubin -inkey "$TMP/pub.pem" -in "$TMP/canonical.txt" -sigfile "$TMP/signature.bin" >/dev/null 2>&1; then
  echo "error: the signature just produced does not verify; not writing an appcast nobody can trust" >&2
  exit 1
fi

JSON="$OUT/appcast.json"
{
  echo '{'
  echo "  \"schema\": 1,"
  echo "  \"channel\": \"$CHANNEL\","
  echo "  \"version\": \"$VERSION\","
  echo "  \"build\": $BUILD_NUMBER,"
  echo "  \"minOS\": \"$MIN_OS\","
  echo "  \"published\": \"$PUBLISHED\","
  echo "  \"notes\": \"$(json_string "$NOTES")\","
  echo "  \"url\": \"$URL\","
  echo "  \"size\": $SIZE,"
  echo "  \"sha256\": \"$SHA256\","
  echo "  \"signature\": \"$SIGNATURE\""
  echo '}'
} > "$JSON"

# The appcast is the product of this script, and the escaping above is the only
# thing standing between release notes and malformed JSON, so prove it parses
# here rather than in a user's updater. (-lint refuses JSON input, but the
# converter reads it.)
if ! plutil -convert xml1 -o /dev/null "$JSON" >/dev/null 2>&1; then
  echo "error: wrote invalid JSON to $JSON" >&2
  exit 1
fi

echo "==> Wrote $JSON"
echo "    version    $VERSION (build $BUILD_NUMBER)"
echo "    channel    $CHANNEL"
echo "    minOS      $MIN_OS"
echo "    published  $PUBLISHED"
echo "    zip        $ZIP"
echo "    size       $SIZE"
echo "    sha256     $SHA256"
echo "    notes hash $NOTES_SHA256"
echo "    url        $URL"
echo "    public key $PUB_B64"

if [[ "$PUBLISH" -eq 1 ]]; then
  echo "==> Publishing v$VERSION to $REPO"
  printf '%s\n' "$NOTES" > "$TMP/notes.md"
  PRERELEASE=""
  if [[ "$CHANNEL" == "prerelease" ]]; then
    PRERELEASE="--prerelease"
  fi
  # $PRERELEASE is deliberately unquoted: it is either empty or the literal
  # --prerelease, and an empty word has to disappear rather than be passed as
  # an empty argument.
  # shellcheck disable=SC2086
  gh release create "v$VERSION" \
    --repo "$REPO" \
    --title "$APP_NAME $VERSION" \
    --notes-file "$TMP/notes.md" \
    $PRERELEASE \
    "$ZIP" "$JSON"
  echo "==> Published https://github.com/$REPO/releases/tag/v$VERSION"
else
  echo "==> Not published (pass --publish to create the GitHub release)"
fi
