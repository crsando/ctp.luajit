#!/usr/bin/env bash
# 查询当日成交并写入 SQLite（幂等，可重复执行）：
#
#   examples/tradelog/run.sh <profile> [symbol] [--db PATH]
#
# 需要 LUA_PATH / CTPC_LIBDIR 已能 require "ctp"（或已 make install）。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

if [ $# -lt 1 ]; then
    echo "usage: $0 <profile> [symbol] [--db PATH]" >&2
    exit 2
fi

profile="$1"; shift
symbol=()
db=()
while [ $# -gt 0 ]; do
    case "$1" in
        --db) db=(--db "$2"); shift 2 ;;
        *) symbol=("$1"); shift ;;
    esac
done

luajit "$here/tradelog.lua" "$profile" ${symbol[@]+"${symbol[@]}"} \
    | uv run --script "$here/import.py" ${db[@]+"${db[@]}"}
