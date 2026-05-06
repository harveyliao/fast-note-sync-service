#!/usr/bin/env bash
set -euo pipefail

OWNER="haierkeys"
REPO="fast-note-sync-service"
PACKAGE_ATTR="fast-note-sync-service"
NIX_DIR="nix"
FLAKE_FILE="${NIX_DIR}/flake.nix"
PLACEHOLDER_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

DRY_RUN=false
COMMIT=false
REQUESTED_VERSION=""
BACKUP_FLAKE=""
UPDATED=false

usage() {
  cat <<'USAGE'
Usage: scripts/update-nix-version.sh [--dry-run] [--commit] [VERSION]

Updates nix/flake.nix to the requested version, or to the latest GitHub
release when VERSION is omitted. VERSION may include or omit a leading "v".

Options:
  --dry-run   Print what would change without editing files or running builds.
  --commit    Commit nix/flake.nix after a successful update.
  -h, --help  Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --commit)
      COMMIT=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$REQUESTED_VERSION" ]; then
        echo "Only one version argument is supported" >&2
        exit 2
      fi
      REQUESTED_VERSION="$1"
      ;;
  esac
  shift
done

if [ ! -f "$FLAKE_FILE" ]; then
  echo "Cannot find $FLAKE_FILE. Run this script from the repository root." >&2
  exit 1
fi

set_output() {
  local key="$1"
  local value="$2"

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

restore_on_failure() {
  local status=$?

  if [ "$status" -ne 0 ] && [ "$UPDATED" = true ] && [ -n "$BACKUP_FLAKE" ] && [ -f "$BACKUP_FLAKE" ]; then
    cp "$BACKUP_FLAKE" "$FLAKE_FILE"
    echo "Restored $FLAKE_FILE after failed update." >&2
  fi

  if [ -n "$BACKUP_FLAKE" ] && [ -f "$BACKUP_FLAKE" ]; then
    rm -f "$BACKUP_FLAKE"
  fi

  exit "$status"
}

normalize_version() {
  local version="$1"
  printf '%s\n' "${version#v}"
}

tag_for_version() {
  local version="$1"
  printf 'v%s\n' "$(normalize_version "$version")"
}

current_version() {
  sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$FLAKE_FILE" | head -n 1
}

latest_release_tag() {
  local tag=""

  if command -v gh >/dev/null 2>&1; then
    tag=$(gh api "repos/${OWNER}/${REPO}/releases/latest" --jq '.tag_name' 2>/dev/null || true)
  fi

  if [ -z "$tag" ] && command -v curl >/dev/null 2>&1; then
    tag=$(curl -fsSL "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest" \
      | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
      | head -n 1 || true)
  fi

  if [ -z "$tag" ]; then
    echo "Install gh or curl, or pass a version argument." >&2
    exit 1
  fi

  printf '%s\n' "$tag"
}

replace_version() {
  local version="$1"
  NEW_VERSION="$version" perl -0pi -e \
    's/version = "[^"]+";/version = "$ENV{NEW_VERSION}";/' \
    "$FLAKE_FILE"
}

replace_source_hash() {
  local hash="$1"
  NEW_HASH="$hash" perl -0pi -e \
    's/(src = pkgs\.fetchFromGitHub \{.*?hash = ")[^"]+(";)/$1$ENV{NEW_HASH}$2/s' \
    "$FLAKE_FILE"
}

replace_vendor_hash() {
  local hash="$1"
  NEW_VENDOR_HASH="$hash" perl -0pi -e \
    's/(vendorHash = ")[^"]+(";)/$1$ENV{NEW_VENDOR_HASH}$2/s' \
    "$FLAKE_FILE"
}

extract_expected_hash() {
  sed -nE 's/.*got:[[:space:]]*(sha256-[A-Za-z0-9+\/=]+).*/\1/p' | tail -n 1
}

capture_expected_hash() {
  local description="$1"
  local output
  local status
  local hash

  set +e
  output=$(cd "$NIX_DIR" && nix build ".#${PACKAGE_ATTR}" --print-out-paths 2>&1)
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    echo "nix build unexpectedly succeeded while resolving ${description}." >&2
    echo "The placeholder hash may not have been applied correctly." >&2
    exit 1
  fi

  hash=$(printf '%s\n' "$output" | extract_expected_hash)
  if [ -z "$hash" ]; then
    echo "Could not parse expected ${description} from nix build output:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  printf '%s\n' "$hash"
}

run_nix_build() {
  cd "$NIX_DIR" && nix build ".#${PACKAGE_ATTR}" --print-out-paths
}

run_nix_check() {
  cd "$NIX_DIR" && nix flake check
}

CURRENT_VERSION=$(current_version)
if [ -z "$CURRENT_VERSION" ]; then
  echo "Could not read version from $FLAKE_FILE" >&2
  exit 1
fi

if [ -n "$REQUESTED_VERSION" ]; then
  TARGET_VERSION=$(normalize_version "$REQUESTED_VERSION")
else
  TARGET_VERSION=$(normalize_version "$(latest_release_tag)")
fi
if [ -z "$TARGET_VERSION" ]; then
  echo "Could not determine target version." >&2
  exit 1
fi
TARGET_TAG=$(tag_for_version "$TARGET_VERSION")

set_output "version" "$TARGET_VERSION"
set_output "version_tag" "$TARGET_TAG"

if [ "$(normalize_version "$CURRENT_VERSION")" = "$TARGET_VERSION" ]; then
  echo "nix/flake.nix is already at ${TARGET_TAG}; nothing to do."
  set_output "changed" "false"
  exit 0
fi

echo "Current Nix version: $(tag_for_version "$CURRENT_VERSION")"
echo "Target Nix version:  ${TARGET_TAG}"

if [ "$DRY_RUN" = true ]; then
  echo "Dry run: would update $FLAKE_FILE, resolve source hash, resolve vendorHash, then run nix build and nix flake check."
  set_output "changed" "true"
  exit 0
fi

BACKUP_FLAKE=$(mktemp)
cp "$FLAKE_FILE" "$BACKUP_FLAKE"
trap restore_on_failure EXIT

replace_version "$TARGET_VERSION"
UPDATED=true
replace_source_hash "$PLACEHOLDER_HASH"

echo "Resolving source hash..."
SOURCE_HASH=$(capture_expected_hash "source hash")
replace_source_hash "$SOURCE_HASH"
echo "Source hash: $SOURCE_HASH"

replace_vendor_hash "$PLACEHOLDER_HASH"

echo "Resolving vendorHash..."
VENDOR_HASH=$(capture_expected_hash "vendorHash")
replace_vendor_hash "$VENDOR_HASH"
echo "Vendor hash: $VENDOR_HASH"

echo "Verifying nix build..."
run_nix_build

echo "Verifying nix flake check..."
run_nix_check

set_output "changed" "true"
set_output "source_hash" "$SOURCE_HASH"
set_output "vendor_hash" "$VENDOR_HASH"

if [ "$COMMIT" = true ]; then
  git add "$FLAKE_FILE"
  git commit -m "chore(nix): bump to ${TARGET_TAG}"
fi

UPDATED=false
rm -f "$BACKUP_FLAKE"
trap - EXIT

echo "Updated $FLAKE_FILE to ${TARGET_TAG}"
