# GeoProxy Mesh Design (WireGuard + Route + Multi-hop)

## Goal

Evolve GeoProxy Server from single-node `inbound → direct` into an optional **mesh-member** profile: nodes discover each other via a peer registry, interconnect with a WireGuard **endpoint**, and forward traffic with `route` / `detour`—without changing the default **edge** install behavior.

Versions (patch bumps only):

| Version | Scope |
|---------|--------|
| **v0.2.24** | Config skeleton: `PROFILE`, optional `endpoints`/`route`/`outbounds` hooks; edge byte-compatible |
| **v0.2.25** | WireGuard endpoint + `mesh init` / `peer add` / `show` + overlay route |
| **v0.2.26** | Peer export / import / sync (mutual awareness) |
| **v0.2.27** | L3 exit hop + L7 outbound detour + doctor checks |

## Product invariants

1. One sing-box process per host.
2. Default `PROFILE=edge`: one inbound protocol → `direct`; no endpoints; no complex route (same as v0.2.23).
3. `PROFILE=mesh-member`: same public inbound + WireGuard endpoint + route to overlay/peers.
4. Hardening (JSON escape, atomic state, checksum upgrades, KiwiVM) unchanged.
5. Data plane has no single traffic hub; registry is control-plane only (file/URL).

## Profiles

| PROFILE | endpoints | outbounds | route |
|---------|-----------|-----------|-------|
| `edge` | omitted | `[direct]` | omitted (sing-box default → first outbound) |
| `mesh-member` | `wg-ep` | `direct` (+ optional hop outbounds later) | overlay → `wg-ep`; `final` → `direct` or exit peer |

## WireGuard overlay

- Prefix default: `10.66.0.0/16`
- Each node: `MESH_OVERLAY_IP` (e.g. `10.66.0.N/32`), `WG_PRIVATE_KEY` / `WG_PUBLIC_KEY`, `WG_LISTEN_PORT` (default `51820`)
- Endpoint tag: `wg-ep`
- Peer `allowed_ips`: peer overlay `/32` (and optionally advertised routes); **never** mutual `0.0.0.0/0` between two non-exit peers (loop prevention)

## Peer schema (`peers.json` / sync document)

```json
{
  "schema": 1,
  "updated_at": "2026-08-21T00:00:00Z",
  "nodes": [
    {
      "node_id": "tile1",
      "public_key": "...",
      "endpoint": "1.2.3.4:51820",
      "overlay_ip": "10.66.0.1",
      "roles": ["edge", "exit"],
      "keepalive": 25
    }
  ]
}
```

Local path: `/etc/geoproxy-server/mesh/peers.json` (mode 600).

## Multi-hop

- **L3**: mark one peer `roles` contains `exit`; members set `MESH_EXIT_NODE_ID` → route default via that peer’s overlay (allowed_ips includes `0.0.0.0/0` **only on the member→exit peer entry**, never exit→member).
- **L7**: optional outbounds with `detour` pointing at another proxy outbound; stored as mesh hop stubs in state (Phase D).

## Anti-loop rules

1. At most one peer entry per local config may carry `0.0.0.0/0` / `::/0`.
2. Exit nodes must not set `MESH_EXIT_NODE_ID` to themselves.
3. `mesh sync` rejects documents that would create bidirectional default routes.
4. doctor warns if WG listen down or peer endpoint empty.

## CLI surface

```text
geoproxy-server mesh init [--overlay-ip 10.66.0.N] [--wg-port 51820]
geoproxy-server mesh show
geoproxy-server mesh peer add <node_id> --pubkey K --endpoint H:P --overlay-ip IP [--exit]
geoproxy-server mesh peer rm <node_id>
geoproxy-server mesh export
geoproxy-server mesh import <file|->
geoproxy-server mesh sync <url-or-file>
geoproxy-server change profile edge|mesh-member
geoproxy-server change mesh-exit <node_id|none>
```

## Non-goals (this track)

- Tailscale/Headscale (optional later)
- System-wide TUN hijack as default
- DHT / zero-registry discovery
- Changing systemd unit name
