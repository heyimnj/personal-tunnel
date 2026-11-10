#!/usr/bin/env bash
# Собирает Libbox.xcframework (iOS) из ядра, закреплённого в core/VERSION.
# Нужны Go (GO_VERSION из core/VERSION) и Xcode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/core-env.sh
source "$ROOT/scripts/core-env.sh"
fetch_core

if [ "$(go env GOVERSION)" != "go$GO_VERSION" ]; then
  echo "warning: Go $(go env GOVERSION), ядро закреплено на go$GO_VERSION" >&2
fi
export PATH="$PATH:$(go env GOPATH)/bin"
go install "github.com/sagernet/gomobile/cmd/gomobile@$GOMOBILE_VERSION"
go install "github.com/sagernet/gomobile/cmd/gobind@$GOMOBILE_VERSION"

VERSION="${SING_BOX_TAG#v}"
LDFLAGS="-X github.com/sagernet/sing-box/constant.Version=$VERSION -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid="

cd "$CORE_CHECKOUT"
rm -rf Libbox.xcframework
echo "Libbox $VERSION, теги: $BUILD_TAGS"
gomobile bind -v \
  -target ios \
  -libname=box \
  -tags-not-macos=with_low_memory \
  -iosversion="$IOS_MIN_VERSION" \
  -trimpath -buildvcs=false \
  -ldflags "$LDFLAGS" \
  -tags "$BUILD_TAGS" \
  ./experimental/libbox

rm -rf "$ROOT/Libbox.xcframework"
mv Libbox.xcframework "$ROOT/Libbox.xcframework"
{
  echo "sing-box $VERSION ($SING_BOX_COMMIT)"
  echo "go $(go env GOVERSION)"
  echo "gomobile $GOMOBILE_VERSION"
  echo "tags $BUILD_TAGS"
} > "$ROOT/Libbox.xcframework/CORE.txt"
ls "$ROOT/Libbox.xcframework"
