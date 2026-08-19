#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/_setup.bash"
}

@test "save_state writes state.env with expected keys and permissions" {
  export PORT=22222
  export UUID="save-uuid"
  export PASSWORD="save-pass"
  export PUBLIC_IP="9.9.9.9"
  export PUBLIC_IP6="::1"
  save_state
  [ -f "$GPS_STATE" ]
  run grep '^PORT=' "$GPS_STATE"
  [ "$status" -eq 0 ]
  run grep '^UUID=' "$GPS_STATE"
  [ "$status" -eq 0 ]
  run grep '^PUBLIC_IP=' "$GPS_STATE"
  [ "$status" -eq 0 ]
  check_perm_600 "$GPS_STATE"
}

@test "state reload preserves shell metacharacters as data" {
  PASSWORD='literal$(not-a-command); "quoted"'
  run save_state
  [ "$status" -eq 0 ]
  PASSWORD=''
  # load_state 必须直接调用：其赋值要留在当前 shell
  load_state
  [ "$PASSWORD" = 'literal$(not-a-command); "quoted"' ]
}
