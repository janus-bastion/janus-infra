#!/usr/bin/env bash

SCRIPT="./janus-replication.sh"
INTERVAL=30

watch -n "$INTERVAL" "$SCRIPT sync" >/dev/null 2>&1
sleep 2
