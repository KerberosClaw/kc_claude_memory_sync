# Fallback Host

> **English summary:** Add multi-path connectivity to hub_reachable() — try primary host (Tailscale) first, fall back to LAN IP if unreachable, auto-restore git remote URL after sync.

## 背景

目前 `hub_reachable()` 只試一個 host（config 裡的 `hub.host`）。如果用 Tailscale hostname，在區網內 Tailscale 沒開時就連不上。反過來，如果用區網 IP，在外面就連不上。

實際場景：MBP 在咖啡店用 Tailscale 連 Mac Mini，回家用區網 IP 連。兩條路不能同時通，但 sync 不該因此失敗。

## 驗收條件

### config

- [ ] AC-1: `config.yaml` 支援 `hub.fallback_host` 欄位（選填），`config.example.yaml` 有範例和說明
- [ ] AC-2: 沒設 `fallback_host` 時，行為跟現在完全一樣（向下相容）

### hub_reachable()

- [ ] AC-3: 先試 `hub.host`（primary），SSH 連得上就直接用
- [ ] AC-4: primary 連不上且 `fallback_host` 有設值時，試 fallback host
- [ ] AC-5: fallback 成功時，暫時切換 git remote URL 到 fallback host
- [ ] AC-6: sync 完成後（不論成功或失敗），自動還原 git remote URL 為 primary host
- [ ] AC-7: primary 和 fallback 都連不上時，回傳 unreachable（跟現在一樣）

### remote URL 還原

- [ ] AC-8: 正常結束時 remote URL 是 primary host
- [ ] AC-9: Ctrl+C 中斷時 remote URL 也要還原（trap EXIT）
- [ ] AC-10: primary 連得上時，如果 remote URL 被之前的 fallback 改過，自動修回 primary

## 不做的事

- 不做多個 fallback host（只支援一個 fallback）
- 不做自動偵測區網 IP（user 自己填）
- 不做 DNS 解析快取
- 不改 setup.sh 的 join/init-hub 流程

## 依賴

- 無新依賴
- 需要 SSH 能連到 primary 或 fallback 其中一個
