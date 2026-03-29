# 結案報告：Fallback Host

> **English summary:** Added multi-path connectivity to hub_reachable() — tries Tailscale hostname first, falls back to LAN IP, auto-restores git remote URL after sync. All 10 acceptance criteria passed.

**Spec:** specs/01-fallback-host
**Status:** completed
**Date:** 2026-03-30

## 摘要

`hub_reachable()` 從單一 host 改為 primary + fallback 雙路連線。Tailscale 不通時自動切到區網 IP 同步，完成後自動還原 git remote URL，不影響下次使用 Tailscale。

## 驗收條件結果

| 驗收條件 | 狀態 |
|---------|------|
| AC-1: config 支援 fallback_host | PASS |
| AC-2: 沒設 fallback_host 向下相容 | PASS |
| AC-3: 先試 primary host | PASS |
| AC-4: primary 失敗試 fallback | PASS |
| AC-5: fallback 成功暫時切 remote URL | PASS |
| AC-6: sync 完成後還原 remote URL | PASS |
| AC-7: 雙路不通回傳 unreachable | PASS |
| AC-8: 正常結束 remote 是 primary | PASS |
| AC-9: Ctrl+C 也還原 | PASS |
| AC-10: primary 連上時修回殘留 | PASS |

## 產出檔案

| 檔案 | 說明 |
|------|------|
| `lib/common.sh` | `load_config` 讀 fallback_host、`hub_reachable` 加 fallback + restore、新增 `_restore_remote()` |
| `config.example.yaml` | 加 `fallback_host` 欄位和註解 |
| `README.md` | 加 fallback 說明、更新 config 範例和限制段落 |
| `README_zh.md` | 同上（正體中文版） |

## 與計畫的偏差

無。已驗證的實作直接 port 回專案 source。

## 備註

- 這個功能是在 `~/dev/claude-memory/.common.sh` 先實驗成功後才 port 回專案的，所以實作和驗證都很順利
- `_restore_remote()` 串在兩個地方：`hub_reachable()` 的 `trap EXIT` 和 `acquire_lock()` 的 trap chain，確保任何退出路徑都能還原
- AC-10（殘留修復）是防禦性設計 — 萬一上次 sync 的 trap 沒觸發（如 kill -9），下次 primary 連得上時會主動修回
