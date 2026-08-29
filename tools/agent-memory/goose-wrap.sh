#!/usr/bin/env bash
#
# goose-wrap.sh — 讓 goose 取得與其他 agent 對等的「開場接手 / 結束固化」行為。
#
# 為什麼需要這個 wrapper：
#   ai-memory 靠各 agent 的 lifecycle hooks（SessionStart / Stop）自動捕捉，
#   但 goose 不在它的原生支援矩陣裡，且 goose 的 hook schema 目前沒有官方文件。
#   這個 wrapper 用「啟動前撈交接 + 離開後固化」把同樣的效果補回來，
#   完全只依賴有文件的 ai-memory 子指令，不猜測 goose 內部設定。
#
# 用法：把平常的 goose 指令原封不動接在後面
#   ./goose-wrap.sh session
#   ./goose-wrap.sh run -t "修掉 login 的 race condition"
#
# 建議加到 shell 設定裡：
#   alias goosem='/path/to/tools/agent-memory/goose-wrap.sh'
#
set -uo pipefail

AGENT_LABEL="goose"
HANDOFF_FILE=".ai-memory-handoff.md"

if [ -t 1 ]; then B=$'\033[1m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else B=""; Y=""; D=""; N=""; fi

if ! command -v ai-memory >/dev/null 2>&1; then
  printf '%s! 找不到 ai-memory，直接啟動 goose（本次不會有記憶捕捉）%s\n' "$Y" "$N" >&2
  exec goose "$@"
fi

# ── 開場：把上次的交接內容撈出來給你看 ────────────────────────────────────────
# goose 讀不到 wrapper 的 stdout，所以這裡有兩個目的：
#   1. 印在終端機上讓「人」先看到上次做到哪
#   2. 落地成檔案，goose 可透過 ai-memory 的 MCP extension 或直接讀檔取用
printf '\n%s── 上次的交接紀錄 ─────────────────────────────%s\n' "$B" "$N"

if ai-memory handoffs >"$HANDOFF_FILE" 2>/dev/null && [ -s "$HANDOFF_FILE" ]; then
  cat "$HANDOFF_FILE"
  printf '\n%s（已存到 %s，可在 goose 裡叫它讀這個檔）%s\n' "$D" "$HANDOFF_FILE" "$N"
else
  printf '%s（沒有未處理的交接，或 ai-memory server 未啟動）%s\n' "$D" "$N"
  rm -f "$HANDOFF_FILE"
fi
printf '%s───────────────────────────────────────────────%s\n\n' "$B" "$N"

# ── 執行 goose，保留它的退出碼 ────────────────────────────────────────────────
goose "$@"
GOOSE_EXIT=$?

# ── 收場：固化這次 session ────────────────────────────────────────────────────
# finalize-session 的 --agent 值若不被接受，退回不帶旗標的版本；
# 兩者都失敗也不覆蓋 goose 本身的退出碼。
printf '\n%s── 固化本次 session 到 ai-memory ──────────────%s\n' "$B" "$N"

if ai-memory finalize-session --agent "$AGENT_LABEL" 2>/dev/null; then
  printf '已寫入（agent=%s）\n' "$AGENT_LABEL"
elif ai-memory finalize-session 2>/dev/null; then
  printf '已寫入（未標記 agent —— 這個 ai-memory 版本不認得 --agent %s）\n' "$AGENT_LABEL"
else
  printf '%s! finalize-session 失敗，本次 session 沒有被固化。%s\n' "$Y" "$N" >&2
  printf '%s  檢查：ai-memory status%s\n' "$D" "$N" >&2
fi
printf '%s───────────────────────────────────────────────%s\n' "$B" "$N"

exit "$GOOSE_EXIT"
