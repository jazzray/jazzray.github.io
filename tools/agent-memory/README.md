# 跨 Agent 開發狀態追蹤 — Layer 1 捕捉層

解決的問題：同一個專案在 Claude Code / Codex / Gemini CLI / Antigravity / Grok / goose
之間切換時，上下文完全斷裂，沒有人知道「昨天是哪個 agent 做到哪」。

這一層負責**自動捕捉**。捕捉不做好，之後任何晨報都只會是 commit summary。

---

## 為什麼選 ai-memory

評估過三個跨 agent 記憶方案：

| 方案 | Stars | 儲存 | 對本案的問題 |
|---|---|---|---|
| [akitaonrails/ai-memory](https://github.com/akitaonrails/ai-memory) | 5.1k | git-versioned markdown + SQLite FTS5 | — **選這個** |
| [AVIDS2/memorix](https://github.com/AVIDS2/memorix) | 706 | 本機 SQLite | 明確不同步到 GitHub，與 Layer 2 衝突 |
| [daystar7777/agent-work-mem](https://github.com/daystar7777/agent-work-mem) | 16 | 純 markdown | 太新太小，不宜當依賴 |

決定性因素是 **ai-memory 用 git-versioned markdown 當儲存**。這代表 Layer 2
（GitHub Actions 產晨報）可以直接讀這些檔案，不需要另外開資料匯出管線。
memorix 星數雖然可觀，但 local-first、不出 git，那條路就斷了。

ai-memory 靠 lifecycle hooks 捕捉，**不需要你或 agent 記得手動寫交接檔** ——
這是它和「規範大家寫 HANDOVER.md」這類做法的根本差異。實務上手寫交接一定會漏。

捕捉的事件：`SessionStart`、`UserPromptSubmit`、`PreToolUse` / `PostToolUse`、`Stop`。

---

## 相容性：你的 6 個 Agent

| Agent | 支援層級 | 已知注意事項 |
|---|---|---|
| Claude Code | 原生 hooks + MCP | 支援度最完整。另有 `--session-aware` 隔離選項 |
| Gemini CLI | 原生 hooks + MCP | 需 v0.26.0+（hooks 預設開啟） |
| Grok Build CLI | 原生 hooks + MCP | **Grok 會忽略 SessionStart 的 stdout**，接手時要自行呼叫 `memory_handoff_accept` |
| Codex CLI | 原生 hooks + MCP | **沒有自動 SessionEnd**，最後一輪後需手動 `ai-memory finalize-session` |
| Antigravity CLI | 原生 hooks + MCP | 同樣需手動 `ai-memory finalize-session --agent antigravity-cli` |
| **goose** | **MCP-only，需 wrapper** | 見下 |

### goose 為什麼是例外

goose 不在 ai-memory 的支援矩陣裡，而 ai-memory **明確聲明沒有通用 fallback**
（未支援的 agent 不提供 `install-mcp` client 也不提供 managed workstream）。

goose 本身確實有 hooks —— 2026/02 加了可 POST JSON 的 HTTP hooks，SessionEnd
lifecycle hook 由 PR #7411 加入。但 `block/goose` 的
`documentation/docs/guides/` 目錄下**沒有 hooks.md**，schema 未公開且隨版本變動。

所以這裡不猜測寫死 hook 設定，改走兩條可驗證的路：

1. **MCP extension** — goose 原生支援 MCP（70+ extensions），把 ai-memory
   掛成 extension，goose 就能主動讀寫共用記憶。
2. **`goose-wrap.sh`** — 啟動前撈交接、離開後呼叫 `finalize-session`，
   把 hook 缺席的部分補回來。只依賴有文件的 ai-memory 子指令。

等 goose 的 hook schema 有官方文件之後，可以把 wrapper 換成真正的 SessionEnd hook。

---

## 安裝

### 1. 裝 ai-memory server

```bash
mkdir -p ~/.local/bin
curl -fsSL https://github.com/akitaonrails/ai-memory/releases/latest/download/ai-memory-wrapper \
  -o ~/.local/bin/ai-memory
chmod +x ~/.local/bin/ai-memory

docker run -d --name ai-memory --restart unless-stopped \
  -p 127.0.0.1:49374:49374 \
  -v ai-memory-data:/data \
  -e AI_MEMORY_LLM_PROVIDER=anthropic \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  akitaonrails/ai-memory:latest
```

Arch Linux 可改用 `yay -S ai-memory-bin` + systemd user service。

### 2. 掛上各 agent

```bash
./setup.sh            # DRY-RUN，只印出會做什麼
./setup.sh --apply    # 確認後才真的寫入
```

腳本會**先問 `ai-memory install-mcp --help` 本機版本實際支援哪些 client**，
再決定要跑哪些指令 —— 不寫死清單，避免版本落差造成錯誤設定。

只處理部分 agent：

```bash
./setup.sh --only claude-code,codex --apply
```

### 3. goose 改用 wrapper 啟動

```bash
alias goosem='/path/to/tools/agent-memory/goose-wrap.sh'
goosem session
```

### 4. 種入既有專案歷史

```bash
cd <你的專案>
ai-memory bootstrap
```

---

## 日常使用

```bash
ai-memory status        # server 與設定狀態
ai-memory continue      # 接續最近一次工作，跨 agent
ai-memory handoffs      # 列出未處理的跨 agent 交接
ai-memory workstreams   # 列出工作流
ai-memory search QUERY  # 全文檢索 wiki
```

managed workstream（更高保真度的跨 agent 續接）：

```bash
ai-memory run claude          # 用 Claude Code 開，自動接手
ai-memory run codex --yolo    # 換 Codex 續同一條工作流
ai-memory run --fresh codex   # 開新 session 但保留歷史
```

### 資料位置

- 設定：`~/.config/ai-memory/config.toml`
- 資料：`~/.local/share/ai-memory/`（Docker volume 掛在 `/data`）
- wiki：`<data_dir>/wiki/` — git-versioned markdown，**Layer 2 的輸入來源**
- 索引：`<data_dir>/db/`

---

## 已知限制

- **Codex 與 Antigravity 沒有自動 SessionEnd**，忘記手動 finalize 就會漏掉那次
  session。建議也包一層 wrapper，比照 `goose-wrap.sh`。
- **Ctrl+C 是暫停不是結束**，不會觸發 SessionEnd。要讓記憶固化請用 `/exit`
  正常離開。
- goose 走 MCP-only，捕捉粒度低於原生 hook 的 agent（沒有 PreToolUse /
  PostToolUse 級別的觀察）。

## 驗證狀態

本目錄的腳本在這個環境**無法端對端測試** —— 沒有 ai-memory server，
也沒有安裝任何一個 agent。已完成的驗證：

- `bash -n` 語法檢查通過
- 缺少 ai-memory 時的失敗路徑實測過（正確印出安裝指引並以 exit 1 結束）
- 所有 ai-memory 子指令與旗標均取自其官方 README，非臆測
- 設計上以 DRY-RUN 為預設，且能力探測交給 `--help` 而非硬編碼

第一次跑請務必先用不帶 `--apply` 的 DRY-RUN 確認。
