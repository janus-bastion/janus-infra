#!/usr/bin/env bash

SCRIPT="./janus-replication.sh"
INTERVAL=30

while true; do
    bash "$SCRIPT" sync >> /root/janus-workspace/janus-watch.log 2>&1
    sleep "$INTERVAL"
done
