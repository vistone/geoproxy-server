#!/usr/bin/env bats

setup() {
  # Source test setup helper using BATS_TEST_DIRNAME
  source "$BATS_TEST_DIRNAME/_setup.bash"
}

@test "gps_write_config creates config with inbounds and outbounds and correct log level" {
  export PORT=43210
  export UUID="test-uuid-1234"
  export PASSWORD="test-pass-1234"
  export LOG_LEVEL="info"

  run gps_write_config
  [ "$status" -eq 0 ]
  [ -f "$GPS_CONFIG" ]
  run grep '"inbounds"' "$GPS_CONFIG"
  [ "$status" -eq 0 ]
  run grep '"outbounds"' "$GPS_CONFIG"
  [ "$status" -eq 0 ]
  run grep '"level"' "$GPS_CONFIG"
  [ "$status" -eq 0 ]
  run grep '"info"' "$GPS_CONFIG"
  [ "$status" -eq 0 ]
  # permissions
  perms=$(stat -c %a "$GPS_CONFIG")
  [ "$perms" -eq 600 ]
}

@test "gps_tuic_urls prints at least one URL (using PUBLIC_IP fallback)" {
  export PORT=54321
  export UUID="u-1"
  export PASSWORD="p-1"
  export PUBLIC_IP="1.2.3.4"
  export PUBLIC_IP6=""
  export GPS_TEST_PREFIX="$GPS_TEST_PREFIX"

  # ensure state file exists
  save_state

  run gps_tuic_urls
  [ "$status" -eq 0 ]
  [[ "$output" =~ "1.2.3.4" ]]
}
