#!/usr/bin/env bash
#
# daily-digest.sh — 產出當日的跨 Agent 交接摘要
#
# 輸出： journal/<YYYY>/<MM>/<YYYY-MM-DD>.<hostname>.md
#
# 檔名帶 hostname 是刻意的：多台機器推同一個 repo 時，每台只寫自己的檔案，
# 路徑天然不重疊，git pull --rebase 不可能產生內容衝突。
#
#   ./daily-digest.sh                    # 產出今天的
#   ./daily-digest.sh --date 2026-08-28  # 補產某一天
#   ./daily-digest.sh --stdout           # 只印出，不寫檔
#
# 所有資料來源都各自 guard：任一個失敗只會讓該區塊留白，不會讓整份產不出來。
#
set -uo pipefail

DATE=""
TO_STDOUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --date)   DATE="${2:-}"; shift ;;
    --stdout) TO_STDOUT=1 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知參數: $1" >&2; exit 2 ;;
  esac
  shift
done

DATE="${DATE:-$(date +%F)}"
if ! printf '%s' "$DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  echo "日期格式須為 YYYY-MM-DD：$DATE" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${AI_MEMORY_DATA_DIR:-$HOME/.local/share/ai-memory}"
WIKI="$DATA_DIR/wiki"

HOST="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"
HOST="${HOST%%.*}"
# 收斂成安全的檔名片段
HOST="$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
HOST="${HOST:-unknown}"

YEAR="${DATE%%-*}"
MONTH="$(printf '%s' "$DATE" | cut -d- -f2)"
OUT_DIR="$REPO_ROOT/journal/$YEAR/$MONTH"
OUT_FILE="$OUT_DIR/$DATE.$HOST.md"

SINCE="$DATE 00:00:00"
UNTIL="$DATE 23:59:59"

have_ai_memory=0
command -v ai-memory >/dev/null 2>&1 && have_ai_memory=1

# ── 組裝 ──────────────────────────────────────────────────────────────────────
emit() {
  printf '# %s · %s\n\n' "$DATE" "$HOST"
  printf '> 由 daily-digest.sh 於 %s 產出\n\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"

  # --- 進行中的工作流 ---
  printf '## 進行中的工作流\n\n'
  if [ "$have_ai_memory" -eq 1 ] && OUT="$(ai-memory workstreams 2>/dev/null)" && [ -n "$OUT" ]; then
    printf '```\n%s\n```\n\n' "$OUT"
  else
    printf '_（無資料：ai-memory 未安裝、server 未啟動，或目前沒有工作流）_\n\n'
  fi

  # --- 未處理的交接 ---
  printf '## 未處理的跨 Agent 交接\n\n'
  if [ "$have_ai_memory" -eq 1 ] && OUT="$(ai-memory handoffs 2>/dev/null)" && [ -n "$OUT" ]; then
    printf '```\n%s\n```\n\n' "$OUT"
  else
    printf '_（沒有未處理的交接）_\n\n'
  fi

  # --- 今日記憶更新 ---
  # wiki 本身就是 git repo，用 git log 取當日變更比任何 CLI 旗標都可靠。
  printf '## 今日記憶更新\n\n'
  if [ ! -d "$WIKI/.git" ]; then
    printf '_（找不到 wiki git repo：%s）_\n\n' "$WIKI"
  else
    # 刻意不用 git log --since/--until：那是「沿 history 走訪、遇到更舊的
    # commit 就停」的語意，只要歷史時序非單調（例如 ai-memory restore-page
    # 從舊版還原後重新 commit），整天的紀錄會被安靜地漏掉。
    # 改成拉一段固定深度的歷史，再自己比對日期，行為完全可預測。
    HASHES="$(git -C "$WIKI" log --all -n 2000 \
                --pretty=format:'%cd %H' --date=format:'%Y-%m-%d' 2>/dev/null \
              | awk -v d="$DATE" '$1 == d { print $2 }')"

    if [ -z "$HASHES" ]; then
      printf '_（這一天沒有記憶更新）_\n\n'
    else
      while IFS= read -r h; do
        [ -z "$h" ] && continue
        git -C "$WIKI" show -s --pretty=format:'- `%h` %s _(%cd)_' \
            --date=format:'%H:%M' "$h" 2>/dev/null
        printf '\n'
      done <<< "$HASHES"
      printf '\n'
    fi

    # --- 變更頁面的摘要 ---
    printf '### 異動的記憶頁面\n\n'
    FILES=""
    if [ -n "$HASHES" ]; then
      while IFS= read -r h; do
        [ -z "$h" ] && continue
        FILES="$FILES$(git -C "$WIKI" show --name-only --pretty=format: "$h" 2>/dev/null)
"
      done <<< "$HASHES"
      FILES="$(printf '%s' "$FILES" | grep -E '\.md$' | sort -u)"
    fi

    if [ -z "$FILES" ]; then
      printf '_（無）_\n\n'
    else
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        path="$WIKI/$f"
        printf '#### `%s`\n\n' "$f"
        if [ ! -f "$path" ]; then
          printf '_（該頁面已被刪除或改名）_\n\n'
          continue
        fi
        title="$(grep -m1 '^# ' "$path" 2>/dev/null | sed 's/^# *//')"
        [ -n "$title" ] && printf '**%s**\n\n' "$title"
        awk '
          /^#/       { next }
          /^[[:space:]]*$/ { if (started) exit; next }
          { print; started=1; if (++n >= 5) exit }
        ' "$path" 2>/dev/null
        printf '\n'
      done <<< "$FILES"
    fi
  fi

  printf -- '---\n\n_原始觀察與逐字轉錄留在本機 `%s`，不隨此摘要外流。_\n' "$DATA_DIR"
}

if [ "$TO_STDOUT" -eq 1 ]; then
  emit
else
  mkdir -p "$OUT_DIR"
  emit > "$OUT_FILE"
  printf '%s\n' "$OUT_FILE"
fi
