#!/usr/bin/env bash
#
# install-schedule.sh — 安裝每日自動同步排程（macOS launchd / Linux systemd）
#
# 預設為 DRY-RUN：印出將寫入的檔案內容與指令，不實際安裝。
#
#   ./install-schedule.sh                    # 演練，預設 18:30
#   ./install-schedule.sh --time 19:00       # 換時間
#   ./install-schedule.sh --apply
#   ./install-schedule.sh --uninstall --apply
#
set -uo pipefail

TIME="18:30"
APPLY=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --time)      TIME="${2:-}"; shift ;;
    --apply)     APPLY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知參數: $1" >&2; exit 2 ;;
  esac
  shift
done

if ! printf '%s' "$TIME" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
  echo "時間格式須為 HH:MM（24 小時制）：$TIME" >&2
  exit 2
fi
# 兩種格式的需求剛好相反：
#   plist 的 <integer> 要純數字（不能有前導零）
#   systemd 的 OnCalendar 要補零的 HH:MM
HOUR="${TIME%%:*}"; MINUTE="${TIME##*:}"
HOUR_NUM="$((10#$HOUR))"; MINUTE_NUM="$((10#$MINUTE))"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$REPO_ROOT/tools/schedule"
LABEL="com.jazzray.ai-workspace-sync"

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; N=""; fi
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }

render() {
  sed -e "s|__REPO_ROOT__|$REPO_ROOT|g" \
      -e "s|__HOME__|$HOME|g" \
      -e "s|__HOUR__|$HOUR|g" \
      -e "s|__MINUTE__|$MINUTE|g" \
      -e "s|__HOUR_NUM__|$HOUR_NUM|g" \
      -e "s|__MINUTE_NUM__|$MINUTE_NUM|g" \
      -e "s|__TIME__|$TIME|g" "$1"
}

run() {
  printf '%s  $ %s%s\n' "$D" "$*" "$N"
  [ "$APPLY" -eq 1 ] && "$@"
  return 0
}

write_file() {
  local dest="$1" content="$2"
  printf '%s  → 寫入 %s%s\n' "$D" "$dest" "$N"
  if [ "$APPLY" -eq 1 ]; then
    mkdir -p "$(dirname "$dest")" || die "無法建立目錄"
    printf '%s\n' "$content" > "$dest" || die "無法寫入 $dest"
  else
    printf '%s┌─────────────────────────────────────────────%s\n' "$D" "$N"
    printf '%s\n' "$content" | sed 's/^/  │ /'
    printf '%s└─────────────────────────────────────────────%s\n' "$D" "$N"
  fi
}

[ -x "$REPO_ROOT/tools/sync.sh" ] || die "找不到可執行的 tools/sync.sh"

OS="$(uname -s)"
step "偵測到作業系統：$OS   排程時間：$TIME"

case "$OS" in
  # ── macOS ────────────────────────────────────────────────────────────────
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    if [ "$UNINSTALL" -eq 1 ]; then
      step "移除 launchd 排程"
      run launchctl bootout "gui/$(id -u)/$LABEL"
      run rm -f "$PLIST"
    else
      step "安裝 launchd 排程"
      write_file "$PLIST" "$(render "$TPL/$LABEL.plist")"
      # bootstrap 前先 bootout，讓重複安裝也能正確覆蓋
      printf '%s  $ launchctl bootout gui/%s/%s  (忽略未載入的錯誤)%s\n' "$D" "$(id -u)" "$LABEL" "$N"
      [ "$APPLY" -eq 1 ] && launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
      run launchctl bootstrap "gui/$(id -u)" "$PLIST"
      printf '\n驗證： launchctl list | grep %s\n' "$LABEL"
      printf '手動觸發一次： launchctl kickstart -p gui/%s/%s\n' "$(id -u)" "$LABEL"
    fi
    ;;

  # ── Linux ────────────────────────────────────────────────────────────────
  Linux)
    UNIT_DIR="$HOME/.config/systemd/user"
    if [ "$UNINSTALL" -eq 1 ]; then
      step "移除 systemd user timer"
      run systemctl --user disable --now ai-workspace-sync.timer
      run rm -f "$UNIT_DIR/ai-workspace-sync.timer" "$UNIT_DIR/ai-workspace-sync.service"
      run systemctl --user daemon-reload
    else
      command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl。若非 systemd 系統，請改用 cron：
   $MINUTE_NUM $HOUR_NUM * * * $REPO_ROOT/tools/sync.sh >> $REPO_ROOT/.sync.log 2>&1"
      step "安裝 systemd user timer"
      write_file "$UNIT_DIR/ai-workspace-sync.service" "$(render "$TPL/ai-workspace-sync.service")"
      write_file "$UNIT_DIR/ai-workspace-sync.timer"   "$(render "$TPL/ai-workspace-sync.timer")"
      run systemctl --user daemon-reload
      run systemctl --user enable --now ai-workspace-sync.timer
      printf '\n驗證： systemctl --user list-timers ai-workspace-sync.timer\n'
      printf '手動觸發一次： systemctl --user start ai-workspace-sync.service\n'
      printf '看記錄： journalctl --user -u ai-workspace-sync.service -n 50\n'
      printf '\n%s提醒：筆電若沒開 lingering，登出後 timer 不會跑：%s\n' "$D" "$N"
      printf '%s  loginctl enable-linger %s%s\n' "$D" "$(id -un)" "$N"
    fi
    ;;

  *)
    die "不支援的作業系統：$OS
   請改用 cron：
   $MINUTE_NUM $HOUR_NUM * * * $REPO_ROOT/tools/sync.sh >> $REPO_ROOT/.sync.log 2>&1"
    ;;
esac

step "完成"
if [ "$APPLY" -eq 1 ]; then
  ok "已套用。"
else
  warn "這是 DRY-RUN，什麼都沒有安裝。"
  printf '確認後重跑：%s%s --apply%s\n' "$B" "$0" "$N"
fi
