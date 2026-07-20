#!/bin/bash
# 一键安装入口：从仓库目录安装到本机
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$ROOT/geoproxy-server.sh" install "$@"
