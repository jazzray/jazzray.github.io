# 安裝與設定

## 為什麼選 ai-memory

評估過三個跨 agent 記憶方案：

| 方案 | Stars | 儲存 | 對本案的問題 |
|---|---|---|---|
| [akitaonrails/ai-memory](https://github.com/akitaonrails/ai-memory) | 5.1k | git-versioned markdown + SQLite FTS5 | — **選這個** |
| [AVIDS2/memorix](https://github.com/AVIDS2/memorix) | 706 | 本機 SQLite | 明確不同步到 GitHub，這條路就斷了 |
| [daystar7777/agent-work-mem](https://github.com/daystar7777/agent-work-mem) | 16 | 純 markdown | 太新太小，不宜當依賴 |

決定性因素是 **wiki 以 git-versioned markdown 儲存** —— 這讓 `daily-digest.sh`
可以直接用 `git log` 精準取出當日變更，不需要依賴任何未公開的 CLI 旗標。

ai-memory 靠 lifecycle hooks 捕捉（`SessionStart`、`UserPromptSubmit`、
`PreToolUse` / `PostToolUse`、`Stop`），**不需要你或 agent 記得手動寫交接檔**。
這是它跟「規範大家寫 HANDOVER.md」這類做法的根本差異 —— 手寫交接實務上一定會漏。

---

## 相容性

| Agent | 支援層級 | 注意事項 |
|---|---|---|
| Claude Code | 原生 hooks + MCP | 支援度最完整。另有 `--session-aware` 隔離選項 |
| Gemini CLI | 原生 hooks + MCP | 需 v0.26.0+（hooks 該版起預設開啟） |
| Grok Build CLI | 原生 hooks + MCP | **忽略 SessionStart 的 stdout**，接手時要自行呼叫 `memory_handoff_accept` |
| Codex CLI | 原生 hooks + MCP | **無自動 SessionEnd** → 用 `agent-wrap.sh codex` |
| Antigravity CLI | 原生 hooks + MCP | **無自動 SessionEnd** → 用 `agent-wrap.sh antigravity` |

注意 Antigravity 的兩個名稱不同：MCP client 是 `antigravity`，hook agent 是
`antigravity-cli`。`agent-wrap.sh` 已經處理這個對應。

---

## 步驟

### 1. 安裝 ai-memory server

**Docker（官方推薦）**

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

**Arch Linux**

```bash
yay -S ai-memory-bin
mkdir -p ~/.config/ai-memory ~/.local/share/ai-memory
ai-memory --data-dir ~/.local/share/ai-memory \
  --config ~/.config/ai-memory/config.toml init
systemctl --user enable --now ai-memory.service
```

### 2. 掛上各 agent

```bash
./tools/setup.sh            # DRY-RUN，只印出會做什麼
./tools/setup.sh --apply
```

腳本會先問 `ai-memory install-mcp --help` 你本機那版**實際支援哪些 client**
再決定跑什麼，而不是寫死清單 —— 版本落差時會警告跳過，不會寫出壞設定。

只處理部分 agent：`./tools/setup.sh --only claude-code,codex --apply`

### 3. 種入既有專案歷史

```bash
cd <你的專案>
ai-memory bootstrap
```

### 4. 安裝每日排程

```bash
./tools/install-schedule.sh              # DRY-RUN，預設 18:30
./tools/install-schedule.sh --time 19:00 --apply
```

macOS 裝 launchd agent，Linux 裝 systemd user timer（`Persistent=true`，
關機錯過的排程開機後會補跑）。移除：`--uninstall --apply`。

Linux 筆電若沒開 lingering，登出後 timer 不會執行：

```bash
loginctl enable-linger $(id -un)
```

### 5. 每台機器重複一次

多台機器各自跑 1–4。因為 journal 檔名帶 hostname，不需要額外協調。

---

## 資料位置

| 路徑 | 內容 | 會不會上 GitHub |
|---|---|---|
| `~/.config/ai-memory/config.toml` | 設定 | 否 |
| `<data_dir>/wiki/` | LLM 整併後的記憶頁面（git repo） | 否，但 digest 會摘錄 |
| `<data_dir>/raw/` | 逐字轉錄片段 | **否** |
| `<data_dir>/db/` | SQLite 索引 | **否** |
| 本 repo `journal/` | 每日交接摘要 | 是 |

`<data_dir>` 預設 `~/.local/share/ai-memory/`，可用 `AI_MEMORY_DATA_DIR` 覆寫。

---

## 安全性

**ai-memory 沒有文件化的憑證過濾。** 官方說法是捕捉「bounded, sanitized」的
prompt（≤16 KiB）與 tool 片段（≤2 KB），但沒有說明是否濾除 API key。

因此 `sync.sh` 用 **gitleaks 當 push 的閘門**：掃到疑似金鑰就中止，不 commit
也不 push。gitleaks 沒安裝時**預設失敗中止**（fail closed），要跳過必須明確加
`--skip-scan`。

```bash
brew install gitleaks          # macOS
# 其他平台見 https://github.com/gitleaks/gitleaks
```

掃到金鑰時，**改 digest 檔沒有用** —— 下次重跑會從 wiki 重新產生並覆寫。
要修的是來源記憶頁面：

```bash
ai-memory search <關鍵字>       # 找出是哪一頁
# 編輯該頁移除憑證，或 ai-memory write-page 覆寫
./tools/sync.sh
```

若外洩的憑證是真的，先去作廢輪替。

---

## 已知限制

- **Ctrl+C 是暫停不是結束**，不觸發 SessionEnd。要固化記憶請用 `/exit`。
- **Codex 與 Antigravity 沒有自動 SessionEnd**，不用 `agent-wrap.sh` 啟動就會
  漏掉整段 session。
- **digest 只摘錄每個記憶頁面的第一段（最多 5 行）**。這降低了外洩面，但不是
  安全保證 —— 金鑰若出現在第一段仍會被帶進去，所以 gitleaks 閘門不能省。
- ai-memory **沒有內建 remote push**，同步完全由本 repo 的 `sync.sh` 負責。

---

## 驗證狀態

這些腳本是在一個沒有 ai-memory server、也沒有安裝任何 agent 的環境中開發的，
**無法端對端測試**。已完成的驗證（用 stub 模擬 `ai-memory` / 各 agent /
`gitleaks` / `hostname` / `uname`）：

- `bash -n` 全部腳本語法檢查
- `setup.sh`：DRY-RUN、`--apply` 確實呼叫、`--only` 過濾、找不到 binary 的失敗
  路徑、版本不支援某 client 時正確警告跳過
- `agent-wrap.sh`：退出碼透傳（agent 回 42 → wrapper 回 42）、`--agent` fallback
- `daily-digest.sh`：分區檔名正確、冪等（重跑覆寫同一檔）、日期格式驗證、
  ai-memory 不在時各區塊正確降級、**非單調 git 歷史下仍取得正確的當日 commit**
- `sync.sh`：gitleaks 未安裝時 fail closed；**植入假金鑰確認 commit 與 push
  都沒發生**（新版 `gitleaks dir` 與舊版 `gitleaks detect` 兩條路徑都測過）；
  `--dry-run` 後暫存區還原；無變更時不產生空 commit
- **兩台機器同日各推一次，檔案並存且無衝突標記**
- `install-schedule.sh`：兩種 OS 的 DRY-RUN；plist 以 `plistlib` 驗證 XML 合法；
  時間格式驗證；前導零在 plist（純數字）與 systemd（補零）分別正確

**還沒驗、要在真實環境確認的**：

- `ai-memory install-mcp --help` 實際列出的 client 名稱是否與腳本探測相符
- 各 agent 掛上 hooks 後是否真的產生觀察
- 排程是否確實在設定時間觸發
- 真實 gitleaks（非 stub）的行為與退出碼

第一次跑務必先用不帶 `--apply` 的 DRY-RUN。
