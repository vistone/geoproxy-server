#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/_setup.bash"
  # shellcheck source=../lib/doctor.sh
  source "$REPO_ROOT/lib/doctor.sh"
}

@test "disk usage percent is an integer between 0 and 100" {
  pct=$(gps_disk_usage_pct "$GPS_LOG_DIR")
  [ -n "$pct" ]
  [[ "$pct" =~ ^[0-9]+$ ]]
  [ "$pct" -ge 0 ]
  [ "$pct" -le 100 ]
}

@test "disk usage percent fails for missing directory" {
  ! gps_disk_usage_pct "$BATS_TEST_TMPDIR/definitely-missing-dir"
}
