#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR: line $LINENO: $BASH_COMMAND" >&2' ERR

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  ./setup.sh [--allow-root]

Options:
  --allow-root    root 実行を明示的に許可する。
                  コンテナ内で root のままセットアップしたい場合だけ使う。

Examples:
  ./setup.sh
  ./setup.sh --allow-root
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
  mise / node はユーザーの $HOME 配下に入るため、
  root で実行すると /root 用の環境になってしまいます。

通常の実行:
  ./setup.sh

コンテナ内で root のまま使いたい場合:
  ./setup.sh --allow-root
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

install_mise() {
  log "mise をセットアップ"

  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v mise >/dev/null 2>&1; then
    curl -fsSL https://mise.run | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if ! command -v mise >/dev/null 2>&1; then
    echo "mise のインストールに失敗しました。" >&2
    exit 1
  fi

  ensure_bashrc_line 'export PATH="$HOME/.local/bin:$PATH"'
  ensure_bashrc_line 'eval "$(mise activate bash)"'

  eval "$(mise activate bash)"
  hash -r
}

install_mise_tools() {
  local tools_file="$1"

  if [ ! -f "$tools_file" ]; then
    echo "mise tools file not found: $tools_file" >&2
    exit 1
  fi

  log "mise tools をインストール"
  log "Tools file: $tools_file"

  local current_dir
  current_dir="$(pwd)"
  cd "$HOME"

  while read -r tool _commands; do
    [ -z "${tool:-}" ] && continue

    log "mise use --global ${tool}"
    mise use --global "$tool"
  done < <(
    grep -vE '^\s*(#|$)' "$tools_file" \
      | sed -E 's/#.*$//' \
      | awk 'NF'
  )

  mise install

  cd "$current_dir"

  eval "$(mise activate bash)"
  hash -r
}

create_directories() {
  local dirs_file="$1"

  if [ ! -f "$dirs_file" ]; then
    echo "directories file not found: $dirs_file" >&2
    exit 1
  fi

  log "ディレクトリを作成"

  while read -r dir; do
    [ -z "${dir:-}" ] && continue

    # ~/xxx を $HOME/xxx に展開
    dir="${dir/#\~/$HOME}"

    log "mkdir -p ${dir}"
    mkdir -p "$dir"
  done < <(
    grep -vE '^\s*(#|$)' "$dirs_file" \
      | sed -E 's/#.*$//' \
      | awk 'NF'
  )
}

repo_name_from_url() {
  local url="$1"

  # trailing slash を削る
  url="${url%/}"

  # 最後の / 以降を取り出す
  local name="${url##*/}"

  # .git を削る
  name="${name%.git}"

  printf '%s\n' "$name"
}

clone_repositories() {
  local repos_file="$1"
  local base_dir="$2"

  if [ ! -f "$repos_file" ]; then
    log "Repos file not found, skip: $repos_file"
    return
  fi

  mkdir -p "$base_dir"

  log "repositories を clone"
  log "Repos file: $repos_file"
  log "Base dir: $base_dir"

  while read -r repo_url repo_dir; do
    [ -z "${repo_url:-}" ] && continue

    if [ -z "${repo_dir:-}" ]; then
      repo_dir="$(repo_name_from_url "$repo_url")"
    fi

    local dest="${base_dir}/${repo_dir}"

    if [ -d "$dest/.git" ]; then
      log "skip: already cloned: $dest"
      continue
    fi

    if [ -e "$dest" ]; then
      echo "既に存在しますが git repository ではありません: $dest" >&2
      continue
    fi

    log "git clone ${repo_url} ${dest}"
    git clone "$repo_url" "$dest"
  done < <(
    grep -vE '^\s*(#|$)' "$repos_file" \
      | sed -E 's/[[:space:]]+#.*$//' \
      | awk 'NF'
  )
}

verify_installation() {
  local tools_file="$1"

  log "インストール確認"

  echo "user:   $(whoami)"
  echo "home:   $HOME"
  echo "shell:  ${SHELL:-unknown}"
  echo

  if command -v mise >/dev/null 2>&1; then
    echo "mise:   $(mise --version)"
  else
    echo "mise:   not found"
    return 1
  fi

  echo
  log "mise current"
  mise current || true

  echo
  log "commands"

  local failed=0

  while read -r tool commands; do
    [ -z "${tool:-}" ] && continue

    # 2列目以降が空なら、その tool は verify 対象なし
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
    echo "一部の mise tools が見つかりません。必要なら次を実行してください:"
    echo
    echo "  exec bash -l"
    echo "  mise install"
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
  local mise_tools_file="${SCRIPT_DIR}/tools/mise.txt"
  local dirs_file="${SCRIPT_DIR}/directories/workspaces.txt"
  local repos_file="${SCRIPT_DIR}/repos/projects.txt"

  install_packages "$pm" "$package_file"
  create_directories "$dirs_file"
  clone_repositories "$repos_file" "$HOME/workspaces/projects"
  install_mise
  install_mise_tools "$mise_tools_file"
  verify_installation "$mise_tools_file"

  cat <<'EOF'

セットアップ完了。

現在のターミナルで command not found になる場合:

  exec bash -l

確認:

  mise current
  node -v
  npm -v

EOF
}

main "$@"
