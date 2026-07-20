# Changelog

All notable changes to this project are documented in this file.

## v0.2.2 - 2026-07-20

- CI: added GitHub Actions workflow running shfmt, shellcheck and bats tests; CI now runs bats with TAP output.
- Code style: applied shfmt across the repo and suppressed intentional shellcheck SC2034 for sourced variables.
- Tests: added bats tests covering config generation, state handling, and KiwiVM traffic guard (warn/stop/resume).
- TUIC: include users.name in inbound (uses machine hostname), add auth_timeout; TUIC URL generation now includes name parameter.
- URL/QR: ensure qrencode is an optional dependency in ensure_deps and gps_cmd_url prints URLs with hostname name param.
- Version bumped to v0.2.2 and added this changelog entry.

(See git history for detailed commits.)
