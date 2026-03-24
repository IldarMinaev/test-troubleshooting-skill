#!/bin/sh
# Launcher script to support both workload and trouble modes

MODE="${MODE:-workload}"

case "$MODE" in
  workload)
    echo "Starting in workload mode..."
    exec python main.py
    ;;
  trouble)
    echo "Starting in trouble generator mode..."
    exec python trouble_main.py
    ;;
  *)
    echo "Unknown MODE: $MODE (valid: workload, trouble)"
    exit 1
    ;;
esac
