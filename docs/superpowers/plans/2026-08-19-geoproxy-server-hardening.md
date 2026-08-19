# GeoProxy Server Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Release the approved high-, medium-, and low-priority hardening work as v0.2.14, v0.2.15, and v0.2.16.

**Architecture:** Keep the Bash, Bats, systemd, and single-instance TUIC architecture. Put validation and state safety helpers in lib/common.sh, configuration serialization in lib/config.sh, and archive integrity verification in lib/download.sh. Each version is an independently testable release commit.

**Tech Stack:** Bash, Bats, curl, sha256sum, flock, sing-box, systemd, ShellCheck, shfmt, GitHub Actions.

## Global Constraints

- Start from v0.2.13. Release only in order: v0.2.14, v0.2.15, v0.2.16.
- Each release commit includes production code, tests, VERSION, and CHANGELOG.md. Add its annotated tag only after release verification.
- Tests must not invoke systemd, download a real core, or write outside GPS_TEST_PREFIX.
- Follow red-green-refactor: observe each new Bats test fail before production code changes.
- Before every release commit run Bats, bash -n, ShellCheck, shfmt, git diff --check, then verify a clean worktree after commit.

## File Map

- lib/common.sh: validation, JSON escaping, safe env serialization/loading, atomic writes, locks.
- lib/config.sh: escaped config generation and URL credential encoding.
- lib/cmd.sh: prefix mode and CLI validation.
- lib/download.sh: checksum manifest validation.
- lib/traffic.sh: locked timer mutations.
- tests/test_install.bats and tests/test_download.bats: new regression suites.
- tests/test_config.bats, tests/test_state.bats, tests/test_traffic.bats: expanded regression suites.
- .gitignore, README.md, CHANGELOG.md, VERSION: release hygiene.

### Task 1: v0.2.14 write failing tests

**Files:** Modify tests/_setup.bash, tests/test_config.bats, tests/test_state.bats. Create tests/test_install.bats and tests/test_download.bats.

- [ ] **Step 1: Add a prefix-mode regression test.**

```bash
@test "install --prefix enables no-systemd mode" {
  source "$REPO_ROOT/lib/systemd.sh"; source "$REPO_ROOT/lib/cmd.sh"
  ensure_deps(){ :; }; gps_download_core(){ :; }; rand_port(){ printf 23456; }
  gen_uuid(){ printf 00000000-0000-4000-8000-000000000000; }
  detect_local_stack(){ STACK_MODE=v4only; }; detect_public_ips(){ :; }
  detect_public_ipv4(){ :; }; detect_public_ipv6(){ :; }; gps_write_config(){ :; }
  save_state(){ :; }; gps_install_unit(){ printf '%s' "$GPS_NO_SYSTEMD"; }
  gps_install_entrypoint(){ :; }; gps_restart_svc(){ :; }; gps_cmd_info(){ :; }; gps_cmd_url(){ :; }
  run gps_cmd_install --prefix "$GPS_TEST_PREFIX/prefix"
  [ "$status" -eq 0 ]; [[ "$output" == *1* ]]
}
```

- [ ] **Step 2: Add escaped-config and safe-state tests.**

```bash
@test "config escapes quote and slash in password" {
  PASSWORD='quoted"\\password'
  run gps_write_config; [ "$status" -eq 0 ]
  run python3 -m json.tool "$GPS_CONFIG"; [ "$status" -eq 0 ]
}
@test "state reload preserves shell metacharacters as data" {
  PASSWORD='literal$(not-a-command); "quoted"'
  save_state; PASSWORD=''; load_state
  [ "$PASSWORD" = 'literal$(not-a-command); "quoted"' ]
}
```

- [ ] **Step 3: Add checksum tests.**

```bash
@test "archive verification rejects checksum mismatch" {
  printf archive-bytes >"$BATS_TEST_TMPDIR/sb.tar.gz"
  printf '%064d  sing-box-test-linux-amd64.tar.gz\n' 0 >"$BATS_TEST_TMPDIR/sha256sums.txt"
  run gps_verify_core_archive "$BATS_TEST_TMPDIR/sb.tar.gz" "$BATS_TEST_TMPDIR/sha256sums.txt" sing-box-test-linux-amd64.tar.gz
  [ "$status" -ne 0 ]
}
@test "archive verification accepts exact checksum" {
  printf archive-bytes >"$BATS_TEST_TMPDIR/sb.tar.gz"
  sum=$(sha256sum "$BATS_TEST_TMPDIR/sb.tar.gz" | awk '{print $1}')
  printf '%s  sing-box-test-linux-amd64.tar.gz\n' "$sum" >"$BATS_TEST_TMPDIR/sha256sums.txt"
  run gps_verify_core_archive "$BATS_TEST_TMPDIR/sb.tar.gz" "$BATS_TEST_TMPDIR/sha256sums.txt" sing-box-test-linux-amd64.tar.gz
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 4: Observe RED.** Run `bats tests/test_install.bats tests/test_config.bats tests/test_state.bats tests/test_download.bats`. Expected: prefix observes 0 and the new safety helpers are missing or fail.

### Task 2: v0.2.14 implement and release

**Files:** Modify lib/common.sh, lib/config.sh, lib/cmd.sh, lib/download.sh, VERSION, CHANGELOG.md, and Task 1 tests.

- [ ] **Step 1: Add reusable validation and JSON helpers.**

```bash
gps_validate_port(){ [[ ${1:-} =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
gps_validate_uuid(){ [[ ${1:-} =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]; }
gps_validate_single_line(){ [[ ${1:-} != *$'\n'* && ${1:-} != *$'\r'* && ${1:-} != *$'\0'* ]]; }
```

Implement gps_json_escape for backslash, quote, backspace, form-feed, line-feed, carriage-return, and tab. Write state and persistence through a same-directory mktemp file, chmod 600, printf '%s=%q\\n' for every value, then mv -f. Refuse to load symlinks; in production require current-user ownership and no group/other write access before source.

- [ ] **Step 2: Apply the helpers at every input boundary.** Validate install and change port/uuid/password/ip/ip6/name/kiwivm values before mutation. Escape every config string. Encode UUID and password through gps_urlencode before generating a TUIC URL.

- [ ] **Step 3: Fix prefix mode.** Set GPS_NO_SYSTEMD=1 unconditionally whenever INSTALL_PREFIX is non-empty, apply paths, and export both variables.

- [ ] **Step 4: Verify core releases before extraction.** Download the release checksum manifest with the archive. gps_verify_core_archive must accept exactly one asset-name line, compare its hash with sha256sum, and fail before tar extraction on absent, duplicate, or mismatched entries.

- [ ] **Step 5: GREEN and release.**

```bash
bats tests/test_install.bats tests/test_config.bats tests/test_state.bats tests/test_download.bats
bash -n install.sh geoproxy-server.sh lib/*.sh
shellcheck -x $(git ls-files '*.sh')
shfmt -d .
git diff --check
```

Set VERSION to v0.2.14 and prepend high-priority notes to CHANGELOG.md. Then run:

```bash
git add VERSION CHANGELOG.md lib tests
git commit -m "fix: harden install inputs and core downloads v0.2.14"
git tag -a v0.2.14 -m "v0.2.14"
git status --short
```

### Task 3: v0.2.15 write failing tests

**Files:** Modify tests/test_state.bats, tests/test_install.bats, and tests/test_traffic.bats.

- [ ] **Step 1: Add atomic state and lock coverage.** Seed GPS_STATE with OLD=1, call save_state, assert the new complete values and no .state.env.tmp.* files remain. Hold the project lock in one test shell for one second, invoke save_state from another shell, and assert the second call completes only after the first releases it.

- [ ] **Step 2: Add validation boundaries.**

```bash
@test "ports are limited to 1 through 65535" {
  gps_validate_port 1; gps_validate_port 65535
  ! gps_validate_port 0; ! gps_validate_port 65536; ! gps_validate_port 12x
}
@test "IPv4 validation rejects out-of-range octets" {
  gps_validate_ipv4 203.0.113.8; ! gps_validate_ipv4 999.0.0.1
}
@test "traffic threshold pair requires warn below stop" {
  gps_validate_traffic_thresholds 80 95; ! gps_validate_traffic_thresholds 95 80
}
```

- [ ] **Step 3: Observe RED.** Run `bats tests/test_state.bats tests/test_install.bats tests/test_traffic.bats`. Expected: missing helper or incorrect semantic results.

### Task 4: v0.2.15 implement and release

**Files:** Modify lib/common.sh, lib/cmd.sh, lib/traffic.sh, VERSION, CHANGELOG.md, and Task 3 tests.

- [ ] **Step 1: Add non-reentrant state locking.**

```bash
gps_with_state_lock(){
  local lock="$GPS_ETC/state.lock"
  mkdir -p "$GPS_ETC"; have_cmd flock || err "需要 flock（util-linux）"
  ( flock -x 9; "$@" ) 9>"$lock"
}
```

Use private unlocked writers below public locked wrappers, preventing self-deadlock. Route CLI and timer mutations through the wrapper.

- [ ] **Step 2: Add strict operational validation.** Parse IPv4 octets and require 0–255. Validate IPv6 through python3 ipaddress; without Python fail with an actionable dependency message, never alter host networking. Validate warning and stop together as 1–100 and warning < stop before saving either.

- [ ] **Step 3: GREEN and release.** Run the full Bats suite and Task 2 static gate. Set VERSION=v0.2.15, update CHANGELOG.md, then:

```bash
git add VERSION CHANGELOG.md lib tests
git commit -m "fix: make state updates atomic and validate operations v0.2.15"
git tag -a v0.2.15 -m "v0.2.15"
git status --short
```

### Task 5: v0.2.16 maintainability release

**Files:** Modify .gitignore, tests/_setup.bash, README.md, CHANGELOG.md, VERSION. Delete tests/tmp/usr/local/lib/geoproxy-server/sing-box.

- [ ] **Step 1: Add hygiene checks and observe RED.** Add Bats teardown that removes only GPS_TEST_PREFIX. After Bats, assert `git status --porcelain -- tests/tmp` is empty. Add a shell test which extracts repository-relative Markdown targets and checks each with test -f. Before cleanup, expect a tracked artifact or stale README target failure.

- [ ] **Step 2: Implement hygiene.** Ignore tests/tmp/, remove the tracked fake binary with git rm, retain fake core creation solely in tests/_setup.bash, fix README design links to repository-local docs, and reconstruct changelog entries v0.2.3–v0.2.16 from Git history.

- [ ] **Step 3: Final verification and release.**

```bash
bats --tap tests
bash -n install.sh geoproxy-server.sh lib/*.sh
shellcheck -x $(git ls-files '*.sh')
shfmt -d .
git diff --check
git status --short
```

Set VERSION=v0.2.16, update CHANGELOG.md, then:

```bash
git add .gitignore README.md CHANGELOG.md VERSION tests .github
git rm tests/tmp/usr/local/lib/geoproxy-server/sing-box
git commit -m "test: complete hardening coverage and project hygiene v0.2.16"
git tag -a v0.2.16 -m "v0.2.16"
git status --short
```

Expected final state: zero Bats failures, clean static checks and worktree, with v0.2.14, v0.2.15, and v0.2.16 pointing at the matching release commits.
