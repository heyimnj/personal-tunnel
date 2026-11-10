#!/usr/bin/env bash
# Читает закрепы из core/VERSION в переменные окружения. Подключается через `source`.
# В macOS bash 3.2, поэтому без process substitution.
CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    [A-Z]*=*) export "${line?}" ;;
  esac
done < "$CORE_ROOT/core/VERSION"
CORE_CHECKOUT="${CORE_CHECKOUT:-$CORE_ROOT/build/sing-box}"

fetch_core() {
  if [ ! -d "$CORE_CHECKOUT/.git" ]; then
    rm -rf "$CORE_CHECKOUT"
    git clone --depth 1 --branch "$SING_BOX_TAG" "$SING_BOX_REMOTE" "$CORE_CHECKOUT"
  fi
  local actual
  actual="$(git -C "$CORE_CHECKOUT" rev-parse HEAD)"
  if [ "$actual" != "$SING_BOX_COMMIT" ]; then
    echo "error: ядро на коммите $actual, ожидался $SING_BOX_COMMIT ($SING_BOX_TAG)" >&2
    return 1
  fi
  # Только подмодули, на которые ссылается go.mod; клиентские приложения не нужны.
  git -C "$CORE_CHECKOUT" submodule update --init --depth 1 \
    submodules/wireguard-go submodules/sing-tun submodules/gvisor
}
