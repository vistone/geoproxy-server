# Multi-Protocol Phase 1–3 Implementation Plan

**Goal:** Ship v0.2.22 (Phase 1) then v0.2.23 (Phase 2+3) on top of v0.2.21.

## Phase 1 — v0.2.22

- [ ] `lib/protocols/_common.sh` shared helpers; registry sources all ids dynamically
- [ ] Modules: `hysteria2.sh`, `vless.sh`, `trojan.sh`, `shadowsocks.sh`
- [ ] `change protocol`, `install --protocol`, menu, url/qr/info/help
- [ ] Persist new state keys; tests; README/design/CHANGELOG/VERSION
- [ ] Commit + tag `v0.2.22`

## Phase 2+3 — v0.2.23

- [ ] Modules: `vmess.sh`, `anytls.sh`, `hysteria.sh`, `naive.sh`, `snell.sh`, `shadowtls.sh`
- [ ] Docs: supported matrix + non-goals in `docs/design.md` / README
- [ ] Tests for registry list + switch + each type field
- [ ] Commit + tag `v0.2.23`
