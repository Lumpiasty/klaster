#!/usr/bin/env bash

WORKSPACE="${WORKSPACE:-/workspace}"
CONF=$WORKSPACE/supervisord.conf

[[ -f "$CONF" ]] || (echo_supervisord_conf > $CONF )

exec supervisord -n -c $CONF "$@"
