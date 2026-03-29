# 實作計畫

> **English summary:** Update common.sh hub_reachable() with fallback logic, add _restore_remote() cleanup, update config.example.yaml and README.

## 做法

已經在 `~/dev/claude-memory/.common.sh` 驗證過可行的實作，現在要把它 port 回專案的 `lib/common.sh`，加上 config 範例和文件更新。

## 關鍵決策

| 決策 | 選擇 | 理由 |
|------|------|------|
| fallback 數量 | 只支援 1 個 | 兩條路（Tailscale + LAN）已涵蓋所有場景，多個 fallback 過度設計 |
| remote URL 還原策略 | trap EXIT | 確保任何退出方式（正常、錯誤、Ctrl+C）都能還原 |
| primary 連上時修復殘留 | 主動修回 | 防止上次 fallback 後 remote URL 沒還原成功的 edge case |

## 風險

| 風險 | 對策 |
|------|------|
| trap 覆蓋 acquire_lock 的 trap | 把 `_restore_remote` 加進 acquire_lock 的 trap chain，不是覆蓋 |
| fallback 時 git push/pull 用到的 remote URL 不一致 | `hub_reachable()` 在 push/pull 之前就切好，整個 sync 期間只用一個 URL |

## 實作順序

1. `lib/common.sh` — 更新 `load_config()` 讀 `fallback_host`，改寫 `hub_reachable()` 加 fallback + restore
2. `config.example.yaml` — 加 `fallback_host` 範例和註解
3. `README.md` — 加 fallback 說明
4. 驗證 — 在 claude-memory repo 確認兩條路都能 sync
