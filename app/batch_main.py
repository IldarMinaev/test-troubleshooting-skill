"""Entry point for batch processing mode."""

import logging
import os
import signal
import sys
import threading
import time

from config import Config
from dbaas_client import DbaasClient, DbaasError
import db
import batch_processor
from batch_processor import JobScheduler, LoadLevel

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s [%(threadName)s] %(name)s — %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("batch_main")

shutdown_event = threading.Event()


def _handle_signal(signum, frame):
    sig_name = signal.Signals(signum).name
    log.info("Received %s, initiating graceful shutdown...", sig_name)
    shutdown_event.set()


def parse_job_list(env_var: str) -> list:
    """Parse comma-separated job list from environment."""
    raw = os.environ.get(env_var, "")
    if not raw:
        return []
    return [s.strip() for s in raw.split(",") if s.strip()]


def parse_load_level(env_var: str, default: str = "medium") -> LoadLevel:
    """Parse load level from environment."""
    raw = os.environ.get(env_var, default).lower()
    try:
        return LoadLevel(raw)
    except ValueError:
        log.warning("Invalid load level '%s', defaulting to medium", raw)
        return LoadLevel.MEDIUM


def main():
    log.info("Starting Batch Processor")

    # 1. Parse configuration
    config = Config()

    # Batch processing configuration
    enabled_jobs = parse_job_list("BATCH_JOBS")
    load_level = parse_load_level("PROCESSING_LOAD")
    duration = int(os.environ.get("JOB_DURATION", "0"))  # 0 = infinite
    ramp_up = int(os.environ.get("WARMUP_PERIOD", "0"))  # seconds to gradually enable
    graceful_shutdown = os.environ.get("GRACEFUL_SHUTDOWN", "true").lower() == "true"
    management_api_enabled = os.environ.get("MANAGEMENT_API_ENABLED", "false").lower() == "true"

    if not enabled_jobs:
        log.error("No batch jobs configured. Set BATCH_JOBS env var.")
        log.info("Available jobs: %s", ", ".join(batch_processor.JOB_REGISTRY.keys()))
        sys.exit(1)

    log.info("Configuration:")
    log.info("  Enabled jobs: %s", enabled_jobs)
    log.info("  Load level: %s", load_level.value)
    log.info("  Duration: %s", f"{duration}s" if duration > 0 else "infinite")
    log.info("  Ramp-up: %ds", ramp_up)
    log.info("  Graceful shutdown: %s", graceful_shutdown)
    log.info("  Management API: %s", management_api_enabled)

    # 2. Provision database via DBAAS
    dbaas = DbaasClient(config.dbaas_url, config.dbaas_user, config.dbaas_password)
    try:
        db_params = dbaas.ensure_database(config.app_namespace)
    except DbaasError as exc:
        log.fatal("Failed to provision database: %s", exc)
        sys.exit(1)

    # 3. Create connection pool (larger pool for batch jobs)
    pool_size = 50
    db.init_pool(db_params, pool_size)

    # 4. Initialize schema
    try:
        db.init_schema()
    except Exception:
        log.exception("Failed to initialize schema")
        db.close_pool()
        sys.exit(1)

    # 5. Initialize job scheduler
    scheduler = JobScheduler()
    scheduler.register_jobs(enabled_jobs)

    # 6. Register signal handlers
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    # 7. Start management API if enabled
    api_thread = None
    if management_api_enabled:
        try:
            from management_api import ManagementAPI
            api = ManagementAPI(scheduler)
            api_thread = threading.Thread(
                target=api.run,
                kwargs={"host": "0.0.0.0", "port": 8080},
                daemon=True,
                name="management-api"
            )
            api_thread.start()
            log.info("Management API started on port 8080")
        except ImportError:
            log.warning("Management API not available (flask not installed)")

    # 8. Warmup: gradually enable jobs
    if ramp_up > 0:
        log.info("Warming up over %d seconds...", ramp_up)
        interval = ramp_up / len(enabled_jobs)
        for job_name in enabled_jobs:
            if shutdown_event.is_set():
                break
            scheduler.start_job(job_name, load_level)
            time.sleep(interval)
        log.info("Warmup complete, all jobs active")
    else:
        # Enable all jobs immediately
        for job_name in enabled_jobs:
            scheduler.start_job(job_name, load_level)

    # 9. Run for specified duration or until shutdown
    log.info("Batch processor running. Send SIGTERM or SIGINT to stop.")

    if duration > 0:
        log.info("Will stop automatically in %d seconds", duration)
        start_time = time.time()
        while not shutdown_event.is_set():
            elapsed = time.time() - start_time
            if elapsed >= duration:
                log.info("Duration reached, stopping...")
                break
            shutdown_event.wait(timeout=min(10, duration - elapsed))
    else:
        # Run indefinitely
        try:
            while not shutdown_event.is_set():
                # Report active jobs every 60 seconds
                active = scheduler.list_active()
                log.info("Active jobs: %s", active if active else "none")
                shutdown_event.wait(timeout=60)
        except KeyboardInterrupt:
            log.info("KeyboardInterrupt received")
            shutdown_event.set()

    # 10. Cleanup
    log.info("Stopping all batch jobs...")
    scheduler.stop_all()

    if graceful_shutdown:
        log.info("Performing cleanup...")
        try:
            conn = db.get_conn()
            conn.autocommit = True
            with conn.cursor() as cur:
                # Optionally truncate tables or drop batch-specific objects
                # For now, just log
                log.info("Cleanup complete")
            db.put_conn(conn)
        except Exception:
            log.exception("Cleanup failed")

    db.close_pool()
    log.info("Shutdown complete")


if __name__ == "__main__":
    main()
