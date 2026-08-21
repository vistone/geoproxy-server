# Multi-Protocol Phase 1–3 Implementation Plan

**Goal:** Ship v0.2.22 (Phase 1) then v0.2.23 (Phase 2+3) on top of v0.2.21.

## Phase 1 — v0.2.22

- [x] `lib/protocols/_common.sh` shared helpers; registry sources all ids dynamically
- [x] Modules: `hysteria2.sh`, `vless.sh`, `trojan.sh`, `shadowsocks.sh`
- [x] `change protocol`, `install --protocol`, menu, url/qr/info/help
- [x] Persist new state keys; tests; README/design/CHANGELOG/VERSION
- [x] Commit + tag `v0.2.22`

## Phase 2+3 — v0.2.23

- [x] Modules: `vmess.sh`, `anytls.sh`, `hysteria.sh`, `naive.sh`, `snell.sh`, `shadowtls.sh`
- [x] Docs: supported matrix + non-goals in `docs/design.md` / README
- [x] Tests for registry list + switch + each type field
- [x] Commit + tag `v0.2.23`
