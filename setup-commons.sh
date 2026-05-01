#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR: line $LINENO: $BASH_COMMAND" >&2' ERR

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  ./base-setup.sh [--allow-root]

Options:
  --allow-root    root 実行を明示的に許可する。
                  コンテナ内で root のままセットアップしたい場合だけ使う。

Examples:
  ./base-setup.sh
  ./base-setup.sh --allow-root
EOF
}

ALLOW_ROOT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-root)
      ALLOW_ROOT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -eq 0 ] && [ "$ALLOW_ROOT" -ne 1 ]; then
  cat <<'EOF'
このスクリプトは通常ユーザーで実行してください。

理由:
  Nix / node / codex / gemini / claude はユーザーの $HOME 配下に入るため、
  root で実行すると /root 用の環境になってしまいます。

通常の実行:
  ./base-setup.sh

コンテナ内で root のまま使いたい場合:
  ./base-setup.sh --allow-root
EOF
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
else
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo が見つかりません。root で sudo を入れるか、--allow-root で実行してください。" >&2
    exit 1
  fi
  SUDO=(sudo)
fi

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  else
    echo "unsupported"
  fi
}

read_package_file() {
  local file="$1"

  grep -vE '^\s*(#|$)' "$file" \
    | sed -E 's/#.*$//' \
    | awk 'NF'
}

install_packages() {
  local pm="$1"
  local package_file="$2"

  if [ ! -f "$package_file" ]; then
    echo "Package file not found: $package_file" >&2
    exit 1
  fi

  mapfile -t packages < <(read_package_file "$package_file")

  if [ "${#packages[@]}" -eq 0 ]; then
    log "No packages to install: $package_file"
    return
  fi

  log "Package manager: $pm"
  log "Package file: $package_file"

  case "$pm" in
    apt)
      "${SUDO[@]}" apt-get update
      DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y "${packages[@]}"
      ;;

    dnf)
      "${SUDO[@]}" dnf install -y "${packages[@]}"
      ;;

    pacman)
      "${SUDO[@]}" pacman -Syu --needed --noconfirm "${packages[@]}"
      ;;

    apk)
      "${SUDO[@]}" apk update
      "${SUDO[@]}" apk add --no-cache "${packages[@]}"
      ;;

    zypper)
      "${SUDO[@]}" zypper --non-interactive refresh
      "${SUDO[@]}" zypper --non-interactive install "${packages[@]}"
      ;;

    *)
      echo "Unsupported package manager: $pm" >&2
      exit 1
      ;;
  esac
}

ensure_bashrc_line() {
  local line="$1"
  local bashrc="$HOME/.bashrc"

  touch "$bashrc"

  if ! grep -qxF "$line" "$bashrc"; then
    echo "$line" >> "$bashrc"
  fi
}

install_nix() {
  log "Nix をセットアップ"

  if ! command -v nix >/dev/null 2>&1; then
    sh <(curl -fsSL https://nixos.org/nix/install) --no-daemon
  fi

  if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  fi

  if ! command -v nix >/dev/null 2>&1; then
    echo "Nix のインストールに失敗しました。" >&2
    exit 1
  fi

  ensure_bashrc_line '. "$HOME/.nix-profile/etc/profile.d/nix.sh"'
}

install_nix_tools() {
  local tools_file="$1"

  if [ ! -f "$tools_file" ]; then
    echo "Nix tools file not found: $tools_file" >&2
    exit 1
  fi

  log "Nix tools をインストール"
  log "Tools file: $tools_file"

  if ! nix-channel --list | grep -q nixpkgs; then
    nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs
  fi
  nix-channel --update

  while read -r package _commands; do
    [ -z "${package:-}" ] && continue
    [[ "$package" == npm:* ]] && continue

    log "nix-env -iA ${package}"
    nix-env -iA "$package"
  done < <(
    grep -vE '^\s*(#|$)' "$tools_file" \
      | sed -E 's/#.*$//' \
      | awk 'NF'
  )

  hash -r

  log "npm global packages をインストール"

  while read -r package _commands; do
    [ -z "${package:-}" ] && continue
    [[ "$package" != npm:* ]] && continue

    local npm_pkg="${package#npm:}"
    log "npm install -g ${npm_pkg}"
    npm install -g "$npm_pkg"
  done < <(
    grep -vE '^\s*(#|$)' "$tools_file" \
      | sed -E 's/#.*$//' \
      | awk 'NF'
  )

  hash -r
}

verify_installation() {
  local tools_file="$1"

  log "インストール確認"

  echo "user:   $(whoami)"
  echo "home:   $HOME"
  echo "shell:  ${SHELL:-unknown}"
  echo

  if command -v nix >/dev/null 2>&1; then
    echo "nix:    $(nix --version)"
  else
    echo "nix:    not found"
    return 1
  fi

  echo
  log "nix-env --query"
  nix-env --query || true

  echo
  log "commands"

  local failed=0

  while read -r tool commands; do
    [ -z "${tool:-}" ] && continue

    if [ -z "${commands:-}" ]; then
      continue
    fi

    for cmd in $commands; do
      if command -v "$cmd" >/dev/null 2>&1; then
        printf "OK   %-10s %s\n" "$cmd" "$(command -v "$cmd")"

        case "$cmd" in
          node|npm|npx|go|codex|gemini|claude|gh|podman|nvim)
            "$cmd" --version 2>/dev/null | head -n 1 || true
            ;;
        esac
      else
        printf "NG   %-10s not found\n" "$cmd"
        failed=1
      fi
    done
  done < <(
    grep -vE '^\s*(#|$)' "$tools_file" \
      | sed -E 's/#.*$//' \
      | awk 'NF'
  )

  echo

  if command -v gh >/dev/null 2>&1; then
    echo "gh:     $(gh --version | head -n 1)"
  else
    echo "gh:     not found"
  fi

  if command -v podman >/dev/null 2>&1; then
    echo "podman: $(podman --version)"
  else
    echo "podman: not found"
  fi

  if command -v nvim >/dev/null 2>&1; then
    echo "nvim:   $(nvim --version | head -n 1)"
  else
    echo "nvim:   not found"
  fi

  if [ "$failed" -ne 0 ]; then
    echo
    echo "一部の Nix tools が見つかりません。必要なら次を実行してください:"
    echo
    echo "  exec bash -l"
    echo "  nix-env --query"
    echo
    return 1
  fi
}

main() {
  local pm
  pm="$(detect_package_manager)"

  if [ "$pm" = "unsupported" ]; then
    echo "対応している package manager が見つかりません: apt, dnf, pacman, apk, zypper" >&2
    exit 1
  fi

  local package_file="${SCRIPT_DIR}/packages/${pm}.txt"
  local nix_tools_file="${SCRIPT_DIR}/tools/nix.txt"

  install_packages "$pm" "$package_file"
  install_nix
  install_nix_tools "$nix_tools_file"
  verify_installation "$nix_tools_file"

  cat <<'EOF'

セットアップ完了。

現在のターミナルで command not found になる場合:

  exec bash -l

確認:

  nix --version
  nix-env --query
  node -v
  npm -v
  command -v codex
  command -v gemini
  command -v claude

EOF
}

main "$@"
