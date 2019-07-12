#!/usr/bin/env bash
set  -eu
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
( cd  "${SCRIPT_DIR}/.." && gem build rmk.gemspec && mv rmk-*.gem "${SCRIPT_DIR}" )
docker build -t wonderix/rmk "$SCRIPT_DIR"
