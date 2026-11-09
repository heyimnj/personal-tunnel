#!/usr/bin/env bash
# Builds Libbox.xcframework (iOS device slice) from the sing-box core pinned in Core/VERSION.
#
#   scripts/build-libbox.sh            # clone the pin into build/core and bind
#   CORE_DIR=/path scripts/build-libbox.sh   # use an existing checkout of the pinned commit
#
# Needs Go (GO_VERSION from Core/VERSION) and Xcode command line tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Read KEY=VALUE pins (macOS ships bash 3.2, where `source <(...)` does not work).
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[A-Z_]+= ]] || continue
  export "${line?}"
done < "$ROOT/Core/VERSION"

CORE_DIR="${CORE_DIR:-$ROOT/build/core}"
OUTPUT="$ROOT/Libbox.xcframework"

if [[ ! -d "$CORE_DIR/.git" ]]; then
  rm -rf "$CORE_DIR"
  git clone --depth 1 --branch "$SING_BOX_TAG" "$SING_BOX_REMOTE" "$CORE_DIR"
fi
actual="$(git -C "$CORE_DIR" rev-parse HEAD)"
if [[ "$actual" != "$SING_BOX_COMMIT" ]]; then
  echo "error: $CORE_DIR is at $actual, expected $SING_BOX_COMMIT ($SING_BOX_TAG)" >&2
  exit 1
fi
# Only the submodules go.mod replaces; the client apps are not needed.
git -C "$CORE_DIR" submodule update --init --depth 1 submodules/wireguard-go submodules/sing-tun submodules/gvisor

go_version="$(go env GOVERSION)"
if [[ "$go_version" != "go$GO_VERSION" ]]; then
  echo "warning: Go $go_version, the core pins go$GO_VERSION" >&2
fi

GOBIN="$(go env GOPATH)/bin"
export PATH="$PATH:$GOBIN"
go install "github.com/sagernet/gomobile/cmd/gomobile@$GOMOBILE_VERSION"
go install "github.com/sagernet/gomobile/cmd/gobind@$GOMOBILE_VERSION"

core_version="${SING_BOX_TAG#v}"
ldflags="-X github.com/sagernet/sing-box/constant.Version=$core_version -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid="

cd "$CORE_DIR"
rm -rf Libbox.xcframework
echo "binding Libbox $core_version with tags: $BUILD_TAGS"
gomobile bind -v \
  -target ios \
  -libname=box \
  -tags-not-macos=with_low_memory \
  -iosversion="$IOS_MIN_VERSION" \
  -trimpath -buildvcs=false \
  -ldflags "$ldflags" \
  -tags "$BUILD_TAGS" \
  ./experimental/libbox

rm -rf "$OUTPUT"
mv Libbox.xcframework "$OUTPUT"
cat > "$OUTPUT/CORE.txt" <<INFO
sing-box $core_version ($SING_BOX_COMMIT)
go $(go env GOVERSION)
gomobile $GOMOBILE_VERSION
tags $BUILD_TAGS
INFO
echo "OK: $OUTPUT"
ls "$OUTPUT"
