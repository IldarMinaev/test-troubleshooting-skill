"""Entry point: config -> DBAAS -> DB pool -> workload scheduler."""

import logging
import signal
import sys
import threading

from config import Config
from dbaas_client import DbaasClient, DbaasError
import db
import workload

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s [%(threadName)s] %(name)s — %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("main")

shutdown_event = threading.Event()


def _handle_signal(signum, frame):
    sig_name = signal.Signals(signum).name
    log.info("Received %s, initiating graceful shutdown...", sig_name)
    shutdown_event.set()


def main():
    # 1. Parse config
    log.info("Starting inventory-service")
    config = Config()
    log.info(
        "Config: workers=%d insert_rate=%.0f MB/h deadlock_interval=%ds long_query=%ds",
        config.worker_count,
        config.insert_rate_mb_per_hour,
        config.deadlock_interval_seconds,
        config.long_query_duration_seconds,
    )
    log.info("Workload mix: %s", config.workload_mix)

    # 2. Provision database via DBAAS
    dbaas = DbaasClient(config.dbaas_url, config.dbaas_user, config.dbaas_password)
    try:
        db_params = dbaas.ensure_database(config.app_namespace)
    except DbaasError as exc:
        log.fatal("Failed to provision database: %s", exc)
        sys.exit(1)

    # 3. Create connection pool
    pool_size = config.worker_count + 5  # workers + deadlock(2) + long-query + overhead
    db.init_pool(db_params, pool_size)

    # 4. Initialize schema
    try:
        db.init_schema()
    except Exception:
        log.exception("Failed to initialize schema")
        db.close_pool()
        sys.exit(1)

    # 5. Register signal handlers
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    # 6. Start workload threads
    threads = workload.start_all(config, shutdown_event)

    # 7. Wait for shutdown signal
    log.info("Service running. Send SIGTERM or SIGINT to stop.")
    try:
        while not shutdown_event.is_set():
            shutdown_event.wait(timeout=1)
    except KeyboardInterrupt:
        log.info("KeyboardInterrupt received")
        shutdown_event.set()

    # 8. Wait for threads to finish
    log.info("Waiting for worker threads to stop...")
    for t in threads:
        t.join(timeout=10)

    # 9. Log final stats
    counts, errors = workload.get_stats()
    log.info("Final stats — completed: %s | errors: %s", counts, errors)

    # 10. Clean up
    db.close_pool()
    log.info("Shutdown complete")


if __name__ == "__main__":
    main()
