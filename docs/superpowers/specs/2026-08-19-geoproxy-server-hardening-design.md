# GeoProxy Server Hardening Design

## Goal

Repair the high-, medium-, and low-priority findings from the v0.2.13 review without changing the single-instance TUIC product model. Deliver the work as three independently verified patch releases: v0.2.14, v0.2.15, and v0.2.16.

## Version and Commit Policy

- Start from v0.2.13 on `main`.
- Use one release commit per priority tier, in order: `v0.2.14` (high), `v0.2.15` (medium), `v0.2.16` (low).
- Each release commit updates `VERSION`, `CHANGELOG.md`, production code, and regression tests together.
- Run the relevant Bats tests before each release commit; run the complete CI-equivalent suite before the final release commit.
- Create an annotated Git tag matching each released version only after its verification succeeds.

This design document is committed separately and does not consume a release version because it has no runtime effect.

## v0.2.14: High-priority correctness and supply-chain hardening

### Prefix installation

`install --prefix DIR` must imply `GPS_NO_SYSTEMD=1` unless the caller has explicitly selected another supported execution mode. The command must not call `systemctl` in prefix mode and must use the existing foreground background-process runner.

### Structured configuration and state

Values that can come from CLI input or persisted state must not be interpolated into JSON or later interpreted as shell source code.

- Validate ports as integers from 1 through 65535.
- Validate UUIDs using the canonical UUID format.
- Reject line breaks and control characters in password, node name, KiwiVM ID, and API key inputs.
- Escape JSON strings before generating `config.json`.
- Serialize `state.env` and the KiwiVM persistence file using shell-safe quoted assignments, then only load regular files owned by root and not writable by group or other users in production mode.
- Percent-encode the UUID and password components in generated TUIC URLs.

### Download verification

When downloading sing-box, retrieve the release checksum manifest over the same HTTPS release channel, select the exact archive entry, and compare a locally computed SHA-256 before extracting or installing the binary. A missing, malformed, or mismatched checksum fails closed and retains the existing core.

## v0.2.15: Medium-priority reliability and validation

### Atomic state updates

All mutations of `state.env` and the durable KiwiVM credential file must use a same-directory temporary file, set mode 0600, and atomically rename it into place. A shared `flock` lock must serialize CLI and systemd timer state mutations.

### Operational validation

IPv4 validation must verify four decimal octets from 0 through 255. IPv6 validation must delegate to a platform parser when available and reject malformed literals. Traffic settings must enforce `warn < stop`, both within 1 through 100, and retain the existing 60-second lower bound for intervals.

## v0.2.16: Low-priority maintainability

- Add Bats coverage for prefix installation, unsafe inputs, checksum failure, atomic-state behavior, and validation boundaries.
- Remove the committed generated `tests/tmp` executable; create it only in test setup and ignore test runtime output.
- Bring `CHANGELOG.md` through the new release version and repair local design-document references in `README.md`.

## Error Handling and Rollback

Validation errors fail before a config or state mutation. Download verification completes before touching the installed core. Atomic writes leave the previous complete state in place if a write is interrupted. A failed release is corrected in a later patch release; no history rewrite or destructive reset is used.

## Verification

For each tier, tests first demonstrate the previous behavior or missing protection, then pass after the minimal implementation. The final gate runs `bash -n`, ShellCheck, shfmt, Bats, `git diff --check`, and a clean-tree verification after each commit/tag.
