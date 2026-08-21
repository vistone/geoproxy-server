# Mesh Implementation Plan (v0.2.24)

**Goal:** Ship WireGuard mesh + route + multi-hop per `docs/superpowers/specs/2026-08-21-mesh-design.md`.

Phase A–D landed together as **v0.2.24** (patch bump).

- [x] PROFILE in state; config hooks for endpoints/outbounds/route
- [x] edge path unchanged; docs + tests
- [x] `lib/mesh/*.sh` WG init/render; mesh CLI basics
- [x] route overlay → wg-ep
- [x] export / import / sync peers.json
- [x] mesh-exit L3; mesh hop L7; doctor mesh checks
- [x] Commit + tag `v0.2.24`
