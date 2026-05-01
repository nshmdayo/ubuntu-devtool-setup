#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR: line $LINENO: $BASH_COMMAND" >&2' ERR

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

if [ "$(id -u)" -eq 0 ]; then
  echo "このスクリプトは root ではなく通常ユーザーで実行してください。"
  echo "例: ./setup-dev.sh"
  exit 1
fi

log "Base packages をインストール"
sudo apt update
sudo apt install -y \
  ca-certificates \
  curl \
  wget \
  gpg \
  git \
  build-essential \
  podman \
  neovim

log "Snap 版 mise があれば削除"
if command -v snap >/dev/null 2>&1 && snap list mise >/dev/null 2>&1; then
  sudo snap remove mise || true
fi

log "GitHub CLI の公式 apt repository を追加"
sudo install -dm 755 /etc/apt/keyrings
sudo install -dm 755 /etc/apt/sources.list.d

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null

sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

log "mise の公式 apt repository を追加"
curl -fsSL https://mise.en.dev/gpg-key.pub \
  | sudo tee /etc/apt/keyrings/mise-archive-keyring.asc >/dev/null

echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.asc] https://mise.en.dev/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/mise.list >/dev/null

log "gh と mise をインストール"
sudo apt update
sudo apt install -y gh mise

log "mise を bash で有効化"
MISE_RC_LINE='eval "$(/usr/bin/mise activate bash)"'

if ! grep -qxF "$MISE_RC_LINE" "$HOME/.bashrc"; then
  echo "$MISE_RC_LINE" >> "$HOME/.bashrc"
fi

# このスクリプト実行中にも mise を有効化する
eval "$(/usr/bin/mise activate bash)"
hash -r

log "Node.js 24 を mise の global default に設定"
mise use --global node@24

log "AI CLI tools を mise 経由でインストール"
mise use --global npm:@openai/codex
mise use --global npm:@google/gemini-cli
mise use --global npm:@anthropic-ai/claude-code

log "mise install を実行"
mise install

# 現在のスクリプト内でも PATH を再評価
eval "$(/usr/bin/mise activate bash)"
hash -r

log "インストール確認"
echo "mise:   $(mise --version)"
echo "node:   $(node -v)"
echo "npm:    $(npm -v)"
echo "gh:     $(gh --version | head -n 1)"

echo
command -v codex || true
command -v gemini || true
command -v claude || true

echo
codex --version || true
gemini --version || true
claude --version || true

cat <<'EOF'

セットアップ完了。

現在のターミナルでまだ command not found になる場合は、次を実行してください。

  exec bash -l

その後、確認:

  command -v codex
  command -v gemini
  command -v claude
  node -v
  npm -v

EOF
