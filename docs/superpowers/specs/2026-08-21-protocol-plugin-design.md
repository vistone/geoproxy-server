# Protocol Plugin Framework Design (Phase 0)

## Goal

Introduce a pluggable inbound-protocol framework without changing runtime behavior for existing installations. After Phase 0, configuration generation and share-URL emission go through a registry whose only registered protocol is still **TUIC**. Later phases add protocols without rewriting the ops stack (upgrade, KiwiVM, dual-stack listen, hardening).

Deliver as **v0.2.21**: backward-compatible architecture release (default remains single-instance TUIC → direct).

## Non-goals (Phase 0)

- No second inbound protocol.
- No `change protocol` CLI/menu yet.
- No systemd unit rename (`geoproxy-tuic` stays).
- No outbound other than `direct`.
- No tun / tproxy / redirect / multi-hop routing.

## Product invariants (must not break)

1. One sing-box process per host.
2. Inbound proxy → `direct` outbound only.
3. Input validation, JSON escaping, atomic `state.env`, download checksums, traffic trip/resume.
4. IPv4/IPv6 adaptive listen (`bindv6only` rules unchanged).
5. Legacy `state.env` without `PROTOCOL` loads as `tuic`.
6. Generated TUIC JSON shape and share URL format remain byte-compatible for the same inputs (same fields/values; whitespace may follow existing heredoc style).

## Architecture

```text
CLI / menu / install
        │
        ▼
  lib/config.sh          # log + dual-stack listen + assemble config.json
        │
        ▼
  lib/protocols/_registry.sh
        │  PROTOCOL ∈ whitelist (Phase 0: tuic only)
        ▼
  lib/protocols/<id>.sh  # inbound JSON fragment + share URLs + validate
        │
        ▼
  sing-box check -c config.json
```

### Registry API

| Function | Role |
|----------|------|
| `gps_protocol_normalize` | Set `PROTOCOL` default `tuic`; reject unknown ids |
| `gps_protocol_validate` | Dispatch field validation for active protocol |
| `gps_proto_inbound_json <tag> <listen>` | One inbound object (no trailing comma) |
| `gps_proto_share_urls` | Print share URL lines (v4/v6 adaptive at caller) |
| `gps_proto_share_url` | First share URL (compat) |
| `gps_protocol_list` | Print registered ids (for future CLI) |

Whitelisted ids live in `GPS_PROTOCOL_IDS` inside `_registry.sh`. Unknown `PROTOCOL` fails closed before writing config.

### TUIC module (`lib/protocols/tuic.sh`)

Owns current TUIC-specific logic moved out of `lib/config.sh`:

- inbound fragment (`type: tuic`, users, congestion_control, TLS alpn h3, …)
- `gps_tuic_urls` / `gps_tuic_url` (kept as public names; registry wrappers call them)
- credential validation reused by install/`change` via `gps_protocol_validate`

### State

- New optional key: `PROTOCOL` (default `tuic` on load and save).
- Existing keys `UUID`, `PASSWORD`, `TUIC_NAME`, `PORT` unchanged.
- `save_state` always persists `PROTOCOL` after normalize.

### Loading order

`geoproxy-server.sh` sources `lib/protocols/_registry.sh` before `lib/config.sh`. The registry sources registered protocol modules. Tests source the same chain via `_setup.bash`.

## Version and docs policy

- Single release: **v0.2.21** (VERSION + CHANGELOG + code + tests in one commit when tagging).
- Update `docs/design.md`, README (product wording + link to this spec), and this design doc.
- Implementation checklist: `docs/superpowers/plans/2026-08-21-protocol-plugin-phase0.md`.

## Error handling

- Unknown protocol → `err` before config/state mutation.
- Protocol validate failure → same as today (install/`change` abort).
- `sing-box check` failure → unchanged fail-closed path.

## Verification

- Existing Bats suites remain green.
- New tests: default PROTOCOL on legacy state; reject unknown PROTOCOL; TUIC config still contains `"type": "tuic"` and valid JSON with escaped password.
- `bash -n`, ShellCheck, shfmt, `git diff --check` as in CI.
