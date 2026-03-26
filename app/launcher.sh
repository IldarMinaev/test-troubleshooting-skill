#!/bin/sh
# Launcher script to support both standard and batch modes

MODE="${MODE:-workload}"

case "$MODE" in
  workload)
    echo "Starting in workload mode..."
    exec python main.py
    ;;
  batch)
    echo "Starting in batch processing mode..."
    exec python batch_main.py
    ;;
  *)
    echo "Unknown MODE: $MODE (valid: workload, batch)"
    exit 1
    ;;
esac
