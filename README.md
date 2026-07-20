# GeoProxy Server

Deploy and manage a single [sing-box](https://sing-box.sagernet.org/) TUIC server on a VPS. GeoProxy Server provides a menu-driven CLI, self-signed TLS, BBR setup, IPv4/IPv6 detection, connection diagnostics, and a systemd service.

## Requirements

- Linux with systemd
- root access
- amd64 or arm64
- Network access to GitHub Releases

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vistone/geoproxy-server/v0.1.1/install.sh)
```

The installer is pinned to version `v0.1.1`. It bootstraps the complete release before installing sing-box.

## Usage

After installation:

```bash
geoproxy-server
geoproxy-server url
geoproxy-server doctor
```

Available commands:

```text
geoproxy-server install [--port N] [--uuid U] [--passwd P] [--ip V4] [--ip6 V6]
geoproxy-server uninstall [-y]
geoproxy-server status | start | stop | restart
geoproxy-server info | url | qr | log [-f]
geoproxy-server change port|uuid|passwd|ip|ip6|ips|log [value|auto]
geoproxy-server upgrade [--force]
geoproxy-server doctor
geoproxy-server bbr
```

`url` prints one or both connection URLs according to the VPS's available IPv4 and IPv6 addresses. The default `debug` log level records TUIC inbound and direct outbound connection activity; use `geoproxy-server log -f` to follow it.

## Installed paths

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/geoproxy-server` | CLI entry point |
| `/usr/local/lib/geoproxy-server/sing-box` | sing-box binary |
| `/etc/geoproxy-server/config.json` | sing-box configuration |
| `/etc/geoproxy-server/state.env` | server state and credentials |
| `/var/log/geoproxy-server/sing-box.log` | service log |

See [docs/design.md](docs/design.md) for the VPS design.
