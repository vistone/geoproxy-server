#!/bin/bash
# Mesh 模块入口

_gps_mesh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mesh/_common.sh
source "${_gps_mesh_dir}/_common.sh"
# shellcheck source=lib/mesh/wireguard.sh
source "${_gps_mesh_dir}/wireguard.sh"
# shellcheck source=lib/mesh/peers.sh
source "${_gps_mesh_dir}/peers.sh"
# shellcheck source=lib/mesh/cli.sh
source "${_gps_mesh_dir}/cli.sh"
unset _gps_mesh_dir
