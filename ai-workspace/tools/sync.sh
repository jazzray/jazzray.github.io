#!/usr/bin/env bash
#
# sync.sh — 產出當日交接摘要，掃過金鑰之後推上私有 repo
#
#   ./sync.sh              # 正常執行（排程呼叫的就是這個）
#   ./sync.sh --dry-run    # 產出 + 掃描 + 印 diff，但不 commit 不 push
#   ./sync.sh --date 2026-08-28
#   ./sync.sh --skip-scan  # 明確跳過金鑰掃描（不建議）
#
# 任一步失敗即中止，且**絕不 push**。
#
set -uo pipefail

DRY_RUN=0
SKIP_SCAN=0
DATE_ARG=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --skip-scan) SKIP_SCAN=1 ;;
    --date)      DATE_ARG=(--date "${2:-}"); shift ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知參數: $1" >&2; exit 2 ;;
  esac
  shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; N=""; fi
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }

[ -d .git ] || die "$REPO_ROOT 不是 git repo。"

# 網路操作重試：排程在筆電上跑，很常遇到剛喚醒還沒連上網
git_retry() {
  local delay=2 attempt
  for attempt in 1 2 3; do
    if git "$@"; then return 0; fi
    if [ "$attempt" -lt 3 ]; then
      warn "git $1 失敗，${delay}s 後重試（第 $attempt/3 次）"
      sleep "$delay"; delay=$((delay * 2))
    fi
  done
  return 1
}

# ── 1. 產出當日摘要 ──────────────────────────────────────────────────────────
step "1. 產出當日交接摘要"
OUT_FILE="$(./tools/daily-digest.sh "${DATE_ARG[@]+"${DATE_ARG[@]}"}")" \
  || die "daily-digest.sh 失敗。"
ok "已產出 ${OUT_FILE#$REPO_ROOT/}"

# ── 2. 金鑰掃描閘門 ──────────────────────────────────────────────────────────
# wiki 頁面是從你的 prompt consolidate 出來的，金鑰有可能被帶進摘要。
# ai-memory 沒有文件化的憑證過濾，所以這道閘門是必要的，不是保險。
step "2. 金鑰掃描"
if [ "$SKIP_SCAN" -eq 1 ]; then
  warn "已用 --skip-scan 跳過掃描。"
elif ! command -v gitleaks >/dev/null 2>&1; then
  die "找不到 gitleaks，為安全起見中止。
   安裝： brew install gitleaks ／ https://github.com/gitleaks/gitleaks
   確定要跳過請明確加上 --skip-scan"
else
  # gitleaks 各版本子指令不同：新版是 `gitleaks dir`，舊版是 `gitleaks detect --no-git`
  SCAN_OUT=""
  if gitleaks dir --help >/dev/null 2>&1; then
    SCAN_OUT="$(gitleaks dir "$REPO_ROOT/journal" --no-banner 2>&1)"; SCAN_RC=$?
  else
    SCAN_OUT="$(gitleaks detect --no-git --source "$REPO_ROOT/journal" --no-banner 2>&1)"; SCAN_RC=$?
  fi

  if [ "$SCAN_RC" -ne 0 ]; then
    printf '%s\n' "$SCAN_OUT" >&2
    die "偵測到疑似金鑰，已中止，未 commit 也未 push。

   注意：直接編輯 ${OUT_FILE#$REPO_ROOT/} 沒有用 —— 下次重跑會從 wiki
   重新產生並覆寫。要修的是**來源記憶頁面**（上面 Finding 指出的內容
   來自 \$AI_MEMORY_DATA_DIR/wiki/ 底下的頁面）：

     1. ai-memory search <關鍵字>      找出是哪一頁
     2. 編輯該頁移除憑證，或 ai-memory write-page 覆寫
     3. 重跑 ./tools/sync.sh

   若該憑證是真的，請先去把它作廢輪替。"
  fi
  ok "掃描通過，未發現金鑰。"
fi

# ── 3. 有變更才繼續 ──────────────────────────────────────────────────────────
step "3. 檢查變更"
git add journal/ || die "git add 失敗。"
if git diff --cached --quiet; then
  ok "沒有變更，結束（不產生空 commit）。"
  exit 0
fi
git diff --cached --stat

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\n%s--- DRY-RUN diff ---%s\n' "$D" "$N"
  git diff --cached
  git reset -q            # 還原暫存區，不留痕跡
  printf '\n'
  warn "DRY-RUN：未 commit、未 push。"
  exit 0
fi

# ── 4. commit ────────────────────────────────────────────────────────────────
step "4. Commit"
HOST="$(hostname 2>/dev/null || uname -n)"; HOST="${HOST%%.*}"
git commit -q -m "journal: $(basename "$OUT_FILE" .md) 交接摘要 (${HOST})" \
  || die "commit 失敗。"
ok "已 commit"

# ── 5. 同步 ──────────────────────────────────────────────────────────────────
# 每台機器只寫自己 hostname 的檔案，路徑不重疊，rebase 不會有內容衝突。
step "5. 與遠端同步"
git_retry pull --rebase --autostash || die "git pull --rebase 失敗，未 push。"
ok "已 rebase 到遠端最新"
git_retry push || die "git push 失敗。"
ok "已推送"

printf '\n%s完成。%s\n' "$G" "$N"
