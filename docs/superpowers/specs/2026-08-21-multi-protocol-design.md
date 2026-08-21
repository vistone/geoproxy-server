# Multi-Protocol Support Design (Phase 1–3)

## Goal

Extend the Phase 0 registry so GeoProxy Server can configure **all sing-box server-side inbound protocols** that make sense as a single-instance exit node (`inbound → direct`), without breaking dual-stack listen, KiwiVM, upgrade, or hardening rules.

## Releases

| Version | Scope |
|---------|--------|
| **v0.2.22** Phase 1 | `hysteria2`, `vless` (Reality), `trojan`, `shadowsocks` (2022) + `change protocol` / menu / `install --protocol` |
| **v0.2.23** Phase 2 | `vmess`, `anytls`, `hysteria`, `naive`, `snell`, `shadowtls` (+ inner SS when needed) |
| **v0.2.23** Phase 3 | Document non-goals: `tun`/`tproxy`/`redirect`/`cloudflared`/`direct` inbound; local-only `mixed`/`socks`/`http` not exposed on public installs |

## Invariants (unchanged)

1. One sing-box process; one **active** `PROTOCOL` at a time (single inbound type in generated config, except ShadowTLS combo which adds a paired inner inbound).
2. Outbound remains `direct` only.
3. Validation + JSON escape + atomic state + checksum upgrades.
4. Legacy `PROTOCOL` empty → `tuic`; `TUIC_NAME` remains the node-name field.
5. systemd unit name stays `geoproxy-tuic` in these releases (rename deferred).

## Registry extensions

Each module implements:

- `gps_proto_<id>_defaults` — fill missing credentials
- `gps_proto_<id>_validate` — strict field checks
- `gps_proto_<id>_inbound_json <tag> <listen>` — one or more JSON objects (ShadowTLS may emit two objects; caller joins with commas carefully — see below)
- `gps_proto_<id>_share_urls` — print share lines (or human export lines when no standard URL)

Shared helpers in `lib/protocols/_common.sh`: TLS cert block, public host iteration, password/UUID/Reality/SS2022 generators, node name.

### Multi-object inbounds

`gps_write_config` continues to call `gps_proto_inbound_json` once per listen address. Protocols that need a **second** inbound (ShadowTLS → Shadowsocks detour) emit a JSON **array fragment** handled by returning multiple objects joined by commas from a single call, using fixed tags (`shadowtls-in`, `ss-inner`) and `detour` on the outer inbound. Listen stack still applies only to the outer listener; inner listens on `127.0.0.1` with a derived port.

## CLI / menu

- `change protocol <id>` — normalize, defaults, validate, rewrite config, restart, print URLs
- `install --protocol <id>` — set before first write
- Menu: select protocol + show current in status line
- `url` / `qr` / `info` dispatch via `gps_proto_share_urls` / `PROTOCOL`

## Credential state keys

| Key | Used by |
|-----|---------|
| `UUID` / `PASSWORD` | tuic, vless, trojan, hy*, anytls, naive, snell, vmess |
| `SS_METHOD` / `SS_PASSWORD` | shadowsocks (SS_PASSWORD may equal PASSWORD) |
| `REALITY_PRIVATE_KEY` / `REALITY_PUBLIC_KEY` / `REALITY_SHORT_ID` / `REALITY_SERVER` | vless |
| `HY_UP_MBPS` / `HY_DOWN_MBPS` / `HY_OBFS` | hysteria / optional hy2 |
| `SHADOWTLS_VERSION` / `SHADOWTLS_HANDSHAKE` / `SHADOWTLS_PASSWORD` | shadowtls |
| `TUIC_NAME` | node name for all share URLs |

## Share URL policy

- Prefer well-known schemes: `tuic://`, `hy2://`, `hysteria://`, `vless://`, `trojan://`, `ss://`, `vmess://` (base64 JSON), `snell://`, `naive+https://` where stable.
- If no stable public scheme: print `export:` lines with essential fields (still escaped / no secrets in argv logs beyond existing info masking).

## Explicit non-goals

- Client/local: `tun`, `redirect`, `tproxy`
- Non-exit: `direct` inbound, `cloudflared`
- Public `mixed`/`socks`/`http` on WAN
- Multi-outbound routing / DNS hijack / full client stack

## Verification

Per release: Bats (new protocol suites), `bash -n`, ShellCheck, shfmt, `git diff --check`, VERSION + CHANGELOG + design sync, annotated tag after green tests.
