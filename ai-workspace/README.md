# ai-workspace

跨 Coding Agent 的開發狀態追蹤。

解決的問題：同一個專案在 Claude Code / Codex / Gemini CLI / Antigravity /
Grok Build CLI 之間切換時，上下文完全斷裂，沒有地方記錄「昨天是哪個 agent
做到哪、卡在哪」。

## 運作方式

```
本機（每台機器）                          這個 repo（private）
─────────────────                        ──────────────────
各 agent 的 lifecycle hooks
  ↓ 自動捕捉，不需要你記得寫
ai-memory
  ↓ session 結束時 LLM 整併成摘要
~/.local/share/ai-memory/wiki/   ← 原始觀察留在這裡，不外流
  ↓ 每日 18:30 排程
daily-digest.sh → sync.sh        → journal/YYYY/MM/YYYY-MM-DD.<host>.md
                  （gitleaks 閘門）
```

`journal/` 只放**精煉後的交接摘要**。原始 prompt 與逐字轉錄永遠留在本機。

## 每天怎麼用

平常照舊工作即可，捕捉是自動的。只有兩件事要記得：

1. **用 `/exit` 正常離開 agent**，不要只按 Ctrl+C —— Ctrl+C 是暫停不是結束，
   不會觸發 SessionEnd，那次 session 就不會被固化。
2. **Codex 和 Antigravity 要用 wrapper 啟動**，因為它們沒有自動 SessionEnd：
   ```bash
   ./tools/agent-wrap.sh codex
   ./tools/agent-wrap.sh antigravity
   ```

隔天接手：

```bash
ai-memory continue      # 接續最近一次工作，跨 agent
ai-memory handoffs      # 看有哪些未處理的交接
cat journal/2026/08/*   # 或直接讀昨天的摘要
```

## 安裝

見 [`docs/setup.md`](docs/setup.md)。摘要：

```bash
# 1. 裝 ai-memory server（docs/setup.md 有完整指令）
# 2. 掛上各 agent —— 預設 DRY-RUN，先看再決定
./tools/setup.sh
./tools/setup.sh --apply

# 3. 種入既有專案歷史
cd <你的專案> && ai-memory bootstrap

# 4. 裝每日排程
./tools/install-schedule.sh
./tools/install-schedule.sh --apply
```

## 工具

| 腳本 | 用途 |
|---|---|
| `tools/setup.sh` | 為各 agent 裝上 MCP + lifecycle hooks |
| `tools/agent-wrap.sh` | 補上 Codex / Antigravity 缺席的 SessionEnd |
| `tools/daily-digest.sh` | 產出當日交接摘要 |
| `tools/sync.sh` | 掃描金鑰後推送（排程呼叫的就是這支） |
| `tools/install-schedule.sh` | 裝 launchd（macOS）或 systemd timer（Linux） |

所有會改動系統狀態的腳本都**預設 DRY-RUN**，要加 `--apply` 才真的執行。

## 多台機器

每台機器只寫自己 hostname 的檔案：

```
journal/2026/08/2026-08-29.macbook.md
journal/2026/08/2026-08-29.workstation.md
```

路徑天然不重疊，`git pull --rebase` 不會產生內容衝突。每台機器各自跑一次
安裝流程即可，不需要額外協調。
