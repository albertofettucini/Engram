#!/bin/bash
# Point the Homebrew formula at a published release. Sets url, version and sha256 in the staging copy
# (packaging/homebrew/engram.rb) and in a DEDICATED tap clone, then prints both diffs. It never commits
# and never pushes: you review the diff, scan the tap, and commit + push the tap yourself (see
# packaging/RELEASE.md).
#
#   bash packaging/bump-formula.sh 0.1.1 ~/Developer/homebrew-engram
#
# The tap's Formula/engram.rb gets the staging copy's whole formula body (so a new desc or caveats ship
# too) under the tap's own header comment.
#
# Refuses Homebrew's own tap folder (/opt/homebrew/…, /usr/local/Homebrew/…, any …/Library/Taps/…):
# that clone has no local git identity, so a commit there would go out under the machine's global one.
# The tap clone must have a LOCAL identity of Joseph.
#
# BUMP_SHA256=<sha256> skips the download (offline runs and tests); otherwise the checksum comes from
# the release's engram-cli-macos-universal.tar.gz.sha256 via `gh release download`.
set -euo pipefail

REPO="albertofettucini/Engram"
ASSET="engram-cli-macos-universal.tar.gz"
TAP_NAME="Joseph"
TAP_EMAIL="joseph.thecouncil@gmail.com"

die() { echo "bump-formula: $*" >&2; exit 1; }

[ $# -eq 2 ] || { echo "usage: bash packaging/bump-formula.sh <x.y.z> <tap-clone>" >&2; exit 2; }
VERSION="${1#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bump-formula: '$1' is not a version like 0.1.1" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGING="$HERE/homebrew/engram.rb"
[ -f "$STAGING" ] || die "can't find the staging formula at $STAGING"

[ -d "$2" ] || die "$2 isn't a folder"
TAP="$(cd "$2" && pwd -P)"   # the real path, so a symlink into Homebrew's folder is caught too
case "$TAP/" in
  /opt/homebrew/*|/usr/local/Homebrew/*|*/Library/Taps/*)
    die "$TAP is Homebrew's own tap folder. Use a dedicated clone, e.g. ~/Developer/homebrew-engram." ;;
esac
git -C "$TAP" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$TAP isn't a git clone"
LOCAL_NAME="$(git -C "$TAP" config --local user.name || true)"
LOCAL_EMAIL="$(git -C "$TAP" config --local user.email || true)"
if [ "$LOCAL_NAME" != "$TAP_NAME" ] || [ "$LOCAL_EMAIL" != "$TAP_EMAIL" ]; then
  echo "bump-formula: the tap clone's local identity is '${LOCAL_NAME:-<unset>}' <${LOCAL_EMAIL:-<unset>}>, not $TAP_NAME. Set it first:" >&2
  echo "  git -C \"$TAP\" config user.name \"$TAP_NAME\"" >&2
  echo "  git -C \"$TAP\" config user.email \"$TAP_EMAIL\"" >&2
  exit 1
fi
FORMULA="$TAP/Formula/engram.rb"
[ -f "$FORMULA" ] || die "$FORMULA doesn't exist"
grep -q '^class Engram < Formula$' "$FORMULA" || die "$FORMULA has no 'class Engram < Formula' line"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SHA="${BUMP_SHA256:-}"
if [ -z "$SHA" ]; then
  command -v gh >/dev/null 2>&1 || die "needs the GitHub CLI (gh) to fetch the checksum, or set BUMP_SHA256"
  gh release download "v$VERSION" --repo "$REPO" --pattern "$ASSET.sha256" --dir "$TMP"
  SHA="$(awk '{ print $1; exit }' "$TMP/$ASSET.sha256")"
fi
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "'$SHA' isn't a sha256"
URL="https://github.com/$REPO/releases/download/v$VERSION/$ASSET"

cp "$STAGING" "$TMP/staging.before.rb"
cp "$FORMULA" "$TMP/tap.before.rb"

set_fields() {
  sed -i '' -E \
    -e "s|^  url \"[^\"]*\"$|  url \"$URL\"|" \
    -e "s|^  version \"[^\"]*\"$|  version \"$VERSION\"|" \
    -e "s|^  sha256 \"[^\"]*\"$|  sha256 \"$SHA\"|" \
    "$1"
  grep -qxF "  url \"$URL\"" "$1" && grep -qxF "  version \"$VERSION\"" "$1" && grep -qxF "  sha256 \"$SHA\"" "$1" \
    || die "couldn't set url, version and sha256 in $1"
  if command -v ruby >/dev/null 2>&1; then ruby -c "$1" >/dev/null || die "$1 isn't valid Ruby after the bump"; fi
}

# 1) the staging copy
set_fields "$STAGING"

# 2) the tap: its own header comment + the staging copy's formula body
sed '/^class Engram < Formula$/,$d' "$TMP/tap.before.rb" > "$TMP/tap.rb"
sed -n '/^class Engram < Formula$/,$p' "$STAGING" >> "$TMP/tap.rb"
cp "$TMP/tap.rb" "$FORMULA"
set_fields "$FORMULA"

echo "----- $STAGING -----"
diff -u "$TMP/staging.before.rb" "$STAGING" || true
echo "----- $FORMULA -----"
diff -u "$TMP/tap.before.rb" "$FORMULA" || true
echo
echo "Formula set to $VERSION (sha256 $SHA). Nothing was committed or pushed. Next:"
echo "  1. Review both diffs above."
echo "  2. In $TAP, run the scan; it must print nothing:"
echo "       git ls-files -z | xargs -0 grep -IE -f ~/.config/council-release/secret-patterns.txt"
echo "  3. Commit and push the tap from that clone, then commit packaging/homebrew/engram.rb in Engram."
