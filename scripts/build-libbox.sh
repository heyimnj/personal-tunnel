#!/usr/bin/env bash
# Собирает библиотеки ядра для iOS. Закрепы — в core/VERSION.
#
#   build-libbox.sh tunnel   Libbox.xcframework для расширения: по умолчанию общая библиотека (TUNNEL_CORE=combined);
#                            с TUNNEL_CORE=singbox — только sing-box на Go TUNNEL_GO_VERSION, как в 2.0.4
#                            (для сравнения на устройстве).
#   build-libbox.sh app      AppCore.xcframework для приложения: libbox + core/bridge + Xray-core, Go GO_VERSION.
#
# Нужны Go и Xcode; нужная версия Go скачивается сама (GOTOOLCHAIN).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/core-env.sh
source "$ROOT/scripts/core-env.sh"
WHAT="${1:?usage: build-libbox.sh tunnel|app}"
TUNNEL_CORE="${TUNNEL_CORE:-combined}"
fetch_core

export PATH="$PATH:$(go env GOPATH)/bin"
GOTOOLCHAIN="go$GO_VERSION" go install "github.com/sagernet/gomobile/cmd/gomobile@$GOMOBILE_VERSION"
GOTOOLCHAIN="go$GO_VERSION" go install "github.com/sagernet/gomobile/cmd/gobind@$GOMOBILE_VERSION"

VERSION="${SING_BOX_TAG#v}"
LDFLAGS="-X github.com/sagernet/sing-box/constant.Version=$VERSION -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid="

bind() { # <output name> <go version> <directory> <packages...>
  local name="$1" go="$2" dir="$3"
  shift 3
  rm -rf "$ROOT/build/$name.xcframework"
  (cd "$dir" && GOTOOLCHAIN="go$go" gomobile bind -v \
    -target ios \
    -libname=box \
    -tags-not-macos=with_low_memory \
    -iosversion="$IOS_MIN_VERSION" \
    -trimpath -buildvcs=false \
    -ldflags "$LDFLAGS" \
    -tags "$BUILD_TAGS" \
    -o "$ROOT/build/$name.xcframework" \
    "$@")
  rm -rf "$ROOT/$name.xcframework"
  mv "$ROOT/build/$name.xcframework" "$ROOT/$name.xcframework"
}

combined() { # <output name>
  fetch_xray
  echo "$1: sing-box $VERSION + Xray-core $XRAY_TAG + bridge, Go $GO_VERSION"
  bind "$1" "$GO_VERSION" "$BRIDGE_DIR" github.com/sagernet/sing-box/experimental/libbox personaltunnel/bridge
  {
    echo "sing-box $VERSION ($SING_BOX_COMMIT)"
    echo "xray-core ${XRAY_TAG#v} ($XRAY_COMMIT)"
    echo "go $GO_VERSION"
    echo "gomobile $GOMOBILE_VERSION"
    echo "tags $BUILD_TAGS"
  } > "$ROOT/$1.xcframework/CORE.txt"
}

case "$WHAT" in
  app)
    combined AppCore
    ;;
  tunnel)
    if [ "$TUNNEL_CORE" = "combined" ]; then
      combined Libbox
    else
      echo "Libbox: sing-box $VERSION, Go $TUNNEL_GO_VERSION"
      bind Libbox "$TUNNEL_GO_VERSION" "$CORE_CHECKOUT" ./experimental/libbox
      {
        echo "sing-box $VERSION ($SING_BOX_COMMIT)"
        echo "go $TUNNEL_GO_VERSION"
        echo "gomobile $GOMOBILE_VERSION"
        echo "tags $BUILD_TAGS"
      } > "$ROOT/Libbox.xcframework/CORE.txt"
    fi
    ;;
  *)
    echo "usage: build-libbox.sh tunnel|app" >&2
    exit 2
    ;;
esac
ls "$ROOT"/*.xcframework
