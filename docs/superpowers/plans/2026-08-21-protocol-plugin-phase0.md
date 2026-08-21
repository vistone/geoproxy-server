# Protocol Plugin Phase 0 — Implementation Plan

> **For agentic workers:** Implement task-by-task. Keep behavior identical for TUIC installs. Do not add hysteria2/vless in this release.

**Goal:** Ship v0.2.21 with a protocol registry and TUIC as the only plugin; docs and VERSION stay in sync.

**Tech Stack:** Bash, Bats, ShellCheck, shfmt (existing CI).

## Global Constraints

- Start from v0.2.20 on `main`.
- One release: **v0.2.21** — production code, tests, VERSION, CHANGELOG, design/plan docs together.
- Do not rename `geoproxy-tuic.service`.
- Do not add `change protocol` yet.
- Tests must not call systemd, download a real core, or write outside `GPS_TEST_PREFIX`.
- Preserve hardening rules: JSON escape, state `%q` + atomic write, input validation.

## File Map

| Path | Change |
|------|--------|
| `lib/protocols/_registry.sh` | **New** — whitelist, normalize, dispatch |
| `lib/protocols/tuic.sh` | **New** — TUIC inbound + share URLs |
| `lib/config.sh` | Protocol-agnostic assemble; call registry |
| `lib/common.sh` | Persist/load `PROTOCOL`; normalize on load |
| `lib/url.sh` / `lib/cmd.sh` | Info/help wording; optional PROTOCOL in info |
| `geoproxy-server.sh` | Source registry before config |
| `tests/_setup.bash` | Source registry |
| `tests/test_protocol.bats` | **New** — normalize / reject / TUIC shape |
| `docs/design.md`, `README.md`, `CHANGELOG.md`, `VERSION` | Sync |
| Spec/plan under `docs/superpowers/` | Already authored |

## Task 1: Registry + TUIC module

- [x] Add `lib/protocols/_registry.sh` with `GPS_PROTOCOL_IDS=(tuic)`, `gps_protocol_normalize`, `gps_protocol_validate`, `gps_proto_inbound_json`, wrappers for share URLs.
- [x] Move `_gps_inbound_json` / URL helpers from `config.sh` into `lib/protocols/tuic.sh` as `gps_proto_tuic_inbound_json` and keep `gps_tuic_urls` / `gps_tuic_url` names.
- [x] Rewrite `gps_write_config` to call `gps_protocol_normalize` then `gps_proto_inbound_json`.

## Task 2: State + entry + tests

- [x] `load_state` / `gps_save_state_unlocked`: normalize and persist `PROTOCOL`.
- [x] Source registry in `geoproxy-server.sh` and `tests/_setup.bash`.
- [x] Add `tests/test_protocol.bats` (legacy default, unknown reject, config type tuic).
- [x] Show `PROTOCOL` in `gps_cmd_info`; soft-update help/README product line.

## Task 3: Docs + version gate

- [x] Set `VERSION` to `v0.2.21`.
- [x] CHANGELOG entry for v0.2.21.
- [x] Update `docs/design.md` + README links to the Phase 0 spec.
- [x] Run: `bats tests`, `bash -n` on scripts, shellcheck, shfmt check.

## Later (out of scope)

- Phase 1: Hysteria2 / VLESS+Reality / Trojan / SS-2022 + `change protocol`.
- Phase 2+: remaining server inbounds; explicit non-support for tun/tproxy.
- Optional unit rename `geoproxy-tuic` → `geoproxy-proxy` (separate release).
