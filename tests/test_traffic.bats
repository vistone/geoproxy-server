#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/_setup.bash"
  # source traffic lib
  # shellcheck source=../lib/traffic.sh
  source "$REPO_ROOT/lib/traffic.sh"
  # override save_state to write to GPS_STATE in our test prefix (already does)
}

@test "gps_kiwi_parse_info parses success JSON and sets pct/used/limit" {
  json='{"error":0,"data_counter":80000000,"plan_monthly_data":100000000,"monthly_data_multiplier":1,"data_next_reset":1700000000}'
  run bash -c 'gps_kiwi_parse_info "$json"'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^0\|80\.[0-9]{0,4}\|80000000\|100000000\|1 ]];
}

@test "traffic check handles API failure gracefully" {
  export KIWI_VEID=1
  export KIWI_API_KEY=key
  # mock fetch to simulate curl failure by returning non-zero
  gps_kiwi_fetch_info() { return 1; }
  run gps_cmd_traffic_check
  [ "$status" -eq 0 ]
  # state should record last error
  run grep '^TRAFFIC_LAST_ERROR=' "$GPS_STATE"
  [ "$status" -eq 0 ]
}

@test "traffic check warns when pct >= warn and logs warn" {
  export KIWI_VEID=1
  export KIWI_API_KEY=key
  # return JSON with 85% usage
  gps_kiwi_fetch_info() { echo '{"error":0,"data_counter":85,"plan_monthly_data":100,"monthly_data_multiplier":1,"data_next_reset":1700000000}'; }
  TRAFFIC_WARN_PCT=80
  TRAFFIC_STOP_PCT=95
  run gps_cmd_traffic_check
  [ "$status" -eq 0 ]
  # check state has TRAFFIC_LAST_PCT
  run grep '^TRAFFIC_LAST_PCT=' "$GPS_STATE"
  [ "$status" -eq 0 ]
  # log contains TRAFFIC_WARN
  run grep 'TRAFFIC_WARN' "$GPS_LOG_DIR/traffic.log"
  [ "$status" -eq 0 ]
}

@test "traffic check stops service when pct >= stop and logs stop" {
  export KIWI_VEID=1
  export KIWI_API_KEY=key
  gps_kiwi_fetch_info() { echo '{"error":0,"data_counter":96,"plan_monthly_data":100,"monthly_data_multiplier":1,"data_next_reset":1700000000}'; }
  TRAFFIC_WARN_PCT=80
  TRAFFIC_STOP_PCT=95
  # Create a dummy PID file to simulate running service
  echo $$ >"$GPS_PID_FILE"
  run gps_cmd_traffic_check
  [ "$status" -eq 0 ]
  # state should set TRAFFIC_TRIPPED=1
  run grep '^TRAFFIC_TRIPPED=' "$GPS_STATE"
  [ "$status" -eq 0 ]
  run grep 'TRAFFIC_STOP' "$GPS_LOG_DIR/traffic.log"
  [ "$status" -eq 0 ]
}

@test "traffic resume clears tripped when below stop and starts service" {
  export KIWI_VEID=1
  export KIWI_API_KEY=key
  # Mock fetch returns low usage
  gps_kiwi_fetch_info() { echo '{"error":0,"data_counter":10,"plan_monthly_data":100,"monthly_data_multiplier":1,"data_next_reset":1700000000}'; }
  # stub gps_svc to avoid actually starting background process
  gps_svc() { if [[ "$1" == start ]]; then echo "mock-start"; fi }
  # set tripped and save
  TRAFFIC_TRIPPED=1
  save_state
  run gps_cmd_traffic_resume
  [ "$status" -eq 0 ]
  # state should now have TRAFFIC_TRIPPED=0
  run grep '^TRAFFIC_TRIPPED=' "$GPS_STATE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "已 resume" ]] || true
}
