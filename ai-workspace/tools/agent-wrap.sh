#!/usr/bin/env bash
#
# agent-wrap.sh — 補上缺席的 SessionEnd，讓記憶確實被固化。
#
# 為什麼需要：
#   ai-memory 靠各 agent 的 lifecycle hooks 自動捕捉，但 Codex 與 Antigravity
#   都沒有自動 SessionEnd —— 官方文件明說要手動呼叫 finalize-session。
#   忘記做，那次 session 就整段漏掉。這個 wrapper 把它變成不用記得的事。
#
# 用法（把平常的指令原封不動接在 agent 名稱後面）：
#   ./agent-wrap.sh codex
#   ./agent-wrap.sh codex --yolo
#   ./agent-wrap.sh antigravity
#
# 建議加進 shell 設定：
#   alias codexm='/path/to/ai-workspace/tools/agent-wrap.sh codex'
#   alias antim='/path/to/ai-workspace/tools/agent-wrap.sh antigravity'
#
# 注意：Ctrl+C 是「暫停」不是「結束」。要讓記憶固化，請在 agent 裡用 /exit
# 正常離開，wrapper 才會接手做 finalize。
#
set -uo pipefail

if [ $# -lt 1 ]; then
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

AGENT="$1"; shift

# agent 名稱 → 執行檔 / ai-memory 的 --agent 標籤
# （兩者不一定同名：Antigravity 的 hook 標籤是 antigravity-cli）
case "$AGENT" in
  codex)        BIN="codex";        LABEL="codex" ;;
  antigravity)  BIN="antigravity";  LABEL="antigravity-cli" ;;
  *)            BIN="$AGENT";       LABEL="$AGENT" ;;
esac

# 執行檔名可用環境變數覆寫，例如 AGENT_WRAP_BIN=antigravity-cli
BIN="${AGENT_WRAP_BIN:-$BIN}"

if [ -t 1 ]; then B=$'\033[1m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else B=""; Y=""; D=""; N=""; fi

if ! command -v "$BIN" >/dev/null 2>&1; then
  printf '%s✗ 找不到執行檔 %s%s\n' "$Y" "$BIN" "$N" >&2
  printf '%s  可用 AGENT_WRAP_BIN=<實際指令> 覆寫%s\n' "$D" "$N" >&2
  exit 127
fi

if ! command -v ai-memory >/dev/null 2>&1; then
  printf '%s! 找不到 ai-memory，直接啟動 %s（本次不會固化記憶）%s\n' "$Y" "$BIN" "$N" >&2
  exec "$BIN" "$@"
fi

# ── 開場：先讓你看到上次的交接 ────────────────────────────────────────────────
printf '\n%s── 未處理的交接 ───────────────────────────────%s\n' "$B" "$N"
if HANDOFFS="$(ai-memory handoffs 2>/dev/null)" && [ -n "$HANDOFFS" ]; then
  printf '%s\n' "$HANDOFFS"
else
  printf '%s（沒有未處理的交接，或 ai-memory server 未啟動）%s\n' "$D" "$N"
fi
printf '%s───────────────────────────────────────────────%s\n\n' "$B" "$N"

# Grok 會忽略 SessionStart 的 stdout；其他 agent 則是由 hook 注入，
# 所以這裡的輸出只是給「人」看的，不依賴 agent 讀得到。

# ── 執行，保留退出碼 ──────────────────────────────────────────────────────────
"$BIN" "$@"
AGENT_EXIT=$?

# ── 收場：固化 ────────────────────────────────────────────────────────────────
printf '\n%s── 固化本次 session ───────────────────────────%s\n' "$B" "$N"
if ai-memory finalize-session --agent "$LABEL" 2>/dev/null; then
  printf '已寫入（agent=%s）\n' "$LABEL"
elif ai-memory finalize-session 2>/dev/null; then
  printf '已寫入（未標記 agent —— 這版 ai-memory 不認得 --agent %s）\n' "$LABEL"
else
  printf '%s! finalize-session 失敗，本次 session 沒有被固化。%s\n' "$Y" "$N" >&2
  printf '%s  檢查：ai-memory status%s\n' "$D" "$N" >&2
fi
printf '%s───────────────────────────────────────────────%s\n' "$B" "$N"

exit "$AGENT_EXIT"
