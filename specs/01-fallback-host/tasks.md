# 任務清單

> **English summary:** Task checklist for fallback-host feature.

**Spec:** 01-fallback-host
**Status:** VERIFIED

## Checklist

- [x] Task 1: lib/common.sh — load_config 讀 fallback_host + hub_reachable 加 fallback 邏輯 + _restore_remote 自動還原
- [x] Task 2: config.example.yaml — 加 fallback_host 範例和註解
- [x] Task 3: README.md — 加 fallback 功能說明
- [x] Task 4: 驗證 — 用 claude-memory repo 測試 Tailscale 和區網兩條路

## 備註

- 已在 ~/dev/claude-memory/.common.sh 驗證過可行，這次是 port 回專案 source
- 改完後要同步回 ~/dev/claude-memory/.common.sh（或用 sync 機制自動同步）
