#!/usr/bin/env bash
#
# setup.sh — 為多個 Coding Agent 掛上 ai-memory 的跨 Agent 記憶／交接層 (Layer 1 捕捉層)
#
# 預設為 DRY-RUN：只顯示會做什麼，不會動到任何 agent 的設定檔。
# 確認無誤後加上 --apply 才會真的寫入。
#
#   ./setup.sh            # 演練，印出將執行的指令
#   ./setup.sh --apply    # 真的套用
#   ./setup.sh --only claude-code,codex --apply
#
set -uo pipefail

APPLY=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --only)  ONLY="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知參數: $1" >&2; exit 2 ;;
  esac
  shift
done

# ── 輸出小工具 ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; D=""; N=""
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; }
head2(){ printf '\n%s%s%s\n' "$B" "$*" "$N"; }

# 執行或演練一道指令
run() {
  if [ "$APPLY" -eq 1 ]; then
    printf '%s  $ %s%s\n' "$D" "$*" "$N"
    "$@"
  else
    printf '%s  $ %s%s\n' "$D" "$*" "$N"
    return 0
  fi
}

# ── 0. 前置檢查 ───────────────────────────────────────────────────────────────
head2 "0. 前置檢查"

if ! command -v ai-memory >/dev/null 2>&1; then
  err "找不到 ai-memory 指令。"
  cat <<'INSTALL'

   請先安裝（擇一）：

   Docker（官方推薦）
     mkdir -p ~/.local/bin
     curl -fsSL https://github.com/akitaonrails/ai-memory/releases/latest/download/ai-memory-wrapper \
       -o ~/.local/bin/ai-memory
     chmod +x ~/.local/bin/ai-memory
     docker run -d --name ai-memory --restart unless-stopped \
       -p 127.0.0.1:49374:49374 -v ai-memory-data:/data \
       -e AI_MEMORY_LLM_PROVIDER=anthropic \
       -e ANTHROPIC_API_KEY=sk-ant-... \
       akitaonrails/ai-memory:latest

   Arch Linux
     yay -S ai-memory-bin
     mkdir -p ~/.config/ai-memory ~/.local/share/ai-memory
     ai-memory --data-dir ~/.local/share/ai-memory \
       --config ~/.config/ai-memory/config.toml init
     systemctl --user enable --now ai-memory.service

   裝好後重跑本腳本。
INSTALL
  exit 1
fi
ok "ai-memory 已安裝：$(command -v ai-memory)"

if ai-memory status >/dev/null 2>&1; then
  ok "ai-memory server 健康檢查通過"
else
  warn "ai-memory status 失敗 —— server 可能沒啟動。install-* 指令可能會失敗。"
  warn "Docker：docker start ai-memory ／ systemd：systemctl --user start ai-memory.service"
fi

# ── 1. 探測這個版本實際支援哪些 client / agent ────────────────────────────────
# 不寫死清單：直接問 ai-memory 自己，避免版本落差造成的錯誤設定。
head2 "1. 探測本機 ai-memory 版本支援的 agent"

MCP_HELP="$(ai-memory install-mcp --help 2>&1 || true)"
HOOK_HELP="$(ai-memory install-hooks --help 2>&1 || true)"

supports_client() { printf '%s' "$MCP_HELP"  | grep -qiw -- "$1"; }
supports_hooks()  { printf '%s' "$HOOK_HELP" | grep -qiw -- "$1"; }

# 格式： <顯示名>|<install-mcp --client 值>|<install-hooks --agent 值>
AGENTS=(
  "Claude Code|claude-code|claude-code"
  "Codex CLI|codex|codex"
  "Gemini CLI|gemini-cli|gemini-cli"
  "Grok Build CLI|grok|grok"
  "Antigravity CLI|antigravity|antigravity-cli"
)

selected() {
  [ -z "$ONLY" ] && return 0
  printf '%s' ",$ONLY," | grep -q ",$1,"
}

# ── 2. 為每個原生支援的 agent 掛上 MCP + hooks ────────────────────────────────
head2 "2. 安裝 MCP server 與 lifecycle hooks"

for entry in "${AGENTS[@]}"; do
  IFS='|' read -r label client agent <<<"$entry"
  selected "$client" || continue

  info ""
  info "${B}${label}${N}"

  if supports_client "$client"; then
    run ai-memory install-mcp --client "$client" --apply
  else
    warn "  這個 ai-memory 版本的 install-mcp 沒列出 client '$client'，跳過。"
    warn "  請自行確認：ai-memory install-mcp --help"
  fi

  if supports_hooks "$agent"; then
    run ai-memory install-hooks --agent "$agent" --apply
  else
    warn "  install-hooks 沒列出 agent '$agent'，跳過。"
  fi
done

# ── 3. goose：MCP-only 模式 ───────────────────────────────────────────────────
# goose 不在 ai-memory 的原生 hook 支援矩陣裡。goose 本身有 hooks（2026/02 起
# 支援 HTTP hooks，SessionEnd 由 PR #7411 加入），但 block/goose 的
# documentation/docs/guides/ 下沒有 hooks.md，schema 未公開且隨版本變動，
# 因此這裡不猜測寫死設定，改走兩條可驗證的路：
#   (a) 把 ai-memory 當成 goose 的 MCP extension（goose 原生支援 MCP）
#   (b) 用 goose-wrap.sh 在 goose 離開後手動觸發 finalize-session
head2 "3. goose（MCP-only，無原生 hook）"

if selected "goose"; then
  if command -v goose >/dev/null 2>&1; then
    ok "偵測到 goose：$(command -v goose)"
    if supports_client "goose"; then
      run ai-memory install-mcp --client goose --apply
      ok "goose 的 MCP 已由 ai-memory 直接設定"
    else
      warn "ai-memory install-mcp 不支援 client 'goose'，請手動加 extension："
      cat <<'GOOSE'

     執行 goose configure → 選 "Add Extension" → "Command-line Extension"
       Name:    ai-memory
       Command: ai-memory
       Args:    mcp
     （實際的 stdio 子指令請以 ai-memory --help 為準）

     設定檔通常在 ~/.config/goose/config.yaml 的 extensions: 區塊。
GOOSE
    fi
    info ""
    info "  session 結束時的記憶固化，請改用本目錄的 wrapper 啟動 goose："
    info "    ${B}./goose-wrap.sh session${N}"
  else
    warn "本機找不到 goose，跳過。"
  fi
else
  info "（未選取 goose）"
fi

# ── 4. 收尾 ───────────────────────────────────────────────────────────────────
head2 "完成"
if [ "$APPLY" -eq 1 ]; then
  ok "已套用設定。"
  info ""
  info "驗證方式："
  info "  ai-memory status         # server 與設定狀態"
  info "  ai-memory workstreams    # 列出工作流"
  info "  ai-memory handoffs       # 列出未處理的跨 agent 交接"
  info ""
  info "首次使用建議先種入既有專案歷史："
  info "  cd <你的專案> && ai-memory bootstrap"
else
  warn "這是 DRY-RUN，什麼都沒有變更。"
  info "確認上面的指令沒問題後，重跑：${B}$0 --apply${N}"
fi
