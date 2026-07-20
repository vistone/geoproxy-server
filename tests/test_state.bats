#!/usr/bin/env bats
load './_setup.bash'

setup() {
  source ./_setup.bash
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
  perms=$(stat -c %a "$GPS_STATE")
  [ "$perms" -eq 600 ]
}
