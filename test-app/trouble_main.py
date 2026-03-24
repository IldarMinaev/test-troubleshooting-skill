"""Entry point for trouble generator mode."""

import logging
import os
import signal
import sys
import threading
import time

from config import Config
from dbaas_client import DbaasClient, DbaasError
import db
import trouble_generator
from trouble_generator import TroubleManager, Intensity

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-7s [%(threadName)s] %(name)s — %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("trouble_main")

shutdown_event = threading.Event()


def _handle_signal(signum, frame):
    sig_name = signal.Signals(signum).name
    log.info("Received %s, initiating graceful shutdown...", sig_name)
    shutdown_event.set()


def parse_scenario_list(env_var: str) -> list:
    """Parse comma-separated scenario list from environment."""
    raw = os.environ.get(env_var, "")
    if not raw:
        return []
    return [s.strip() for s in raw.split(",") if s.strip()]


def parse_intensity(env_var: str, default: str = "medium") -> Intensity:
    """Parse intensity from environment."""
    raw = os.environ.get(env_var, default).lower()
    try:
        return Intensity(raw)
    except ValueError:
        log.warning("Invalid intensity '%s', defaulting to medium", raw)
        return Intensity.MEDIUM


def main():
    log.info("Starting Trouble Generator")

    # 1. Parse configuration
    config = Config()

    # Trouble-specific configuration
    enabled_scenarios = parse_scenario_list("TROUBLE_SCENARIOS")
    intensity = parse_intensity("TROUBLE_INTENSITY")
    duration = int(os.environ.get("TROUBLE_DURATION", "0"))  # 0 = infinite
    ramp_up = int(os.environ.get("TROUBLE_RAMP_UP", "0"))  # seconds to gradually enable
    cleanup_on_exit = os.environ.get("CLEANUP_ON_EXIT", "true").lower() == "true"
    control_api_enabled = os.environ.get("CONTROL_API_ENABLED", "false").lower() == "true"

    if not enabled_scenarios:
        log.error("No trouble scenarios enabled. Set TROUBLE_SCENARIOS env var.")
        log.info("Available scenarios: %s", ", ".join(trouble_generator.SCENARIO_REGISTRY.keys()))
        sys.exit(1)

    log.info("Configuration:")
    log.info("  Enabled scenarios: %s", enabled_scenarios)
    log.info("  Intensity: %s", intensity.value)
    log.info("  Duration: %s", f"{duration}s" if duration > 0 else "infinite")
    log.info("  Ramp-up: %ds", ramp_up)
    log.info("  Cleanup on exit: %s", cleanup_on_exit)
    log.info("  Control API: %s", control_api_enabled)

    # 2. Provision database via DBAAS
    dbaas = DbaasClient(config.dbaas_url, config.dbaas_user, config.dbaas_password)
    try:
        db_params = dbaas.ensure_database(config.app_namespace)
    except DbaasError as exc:
        log.fatal("Failed to provision database: %s", exc)
        sys.exit(1)

    # 3. Create connection pool (larger pool for trouble scenarios)
    pool_size = 50
    db.init_pool(db_params, pool_size)

    # 4. Initialize schema
    try:
        db.init_schema()
    except Exception:
        log.exception("Failed to initialize schema")
        db.close_pool()
        sys.exit(1)

    # 5. Initialize trouble manager
    manager = TroubleManager()
    manager.register_scenarios(enabled_scenarios)

    # 6. Register signal handlers
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    # 7. Start control API if enabled
    api_thread = None
    if control_api_enabled:
        try:
            from control_api import ControlAPI
            api = ControlAPI(manager)
            api_thread = threading.Thread(
                target=api.run,
                kwargs={"host": "0.0.0.0", "port": 8080},
                daemon=True,
                name="control-api"
            )
            api_thread.start()
            log.info("Control API started on port 8080")
        except ImportError:
            log.warning("Control API not available (flask not installed)")

    # 8. Ramp-up: gradually enable scenarios
    if ramp_up > 0:
        log.info("Ramping up over %d seconds...", ramp_up)
        interval = ramp_up / len(enabled_scenarios)
        for scenario_name in enabled_scenarios:
            if shutdown_event.is_set():
                break
            manager.start_scenario(scenario_name, intensity)
            time.sleep(interval)
        log.info("Ramp-up complete, all scenarios active")
    else:
        # Enable all scenarios immediately
        for scenario_name in enabled_scenarios:
            manager.start_scenario(scenario_name, intensity)

    # 9. Run for specified duration or until shutdown
    log.info("Trouble generator running. Send SIGTERM or SIGINT to stop.")

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
                # Report active scenarios every 60 seconds
                active = manager.list_active()
                log.info("Active scenarios: %s", active if active else "none")
                shutdown_event.wait(timeout=60)
        except KeyboardInterrupt:
            log.info("KeyboardInterrupt received")
            shutdown_event.set()

    # 10. Cleanup
    log.info("Stopping all trouble scenarios...")
    manager.stop_all()

    if cleanup_on_exit:
        log.info("Performing cleanup...")
        try:
            # Drop trouble-specific data
            conn = db.get_conn()
            conn.autocommit = True
            with conn.cursor() as cur:
                # Optionally truncate tables or drop trouble-specific objects
                # For now, just log
                log.info("Cleanup complete")
            db.put_conn(conn)
        except Exception:
            log.exception("Cleanup failed")

    db.close_pool()
    log.info("Shutdown complete")


if __name__ == "__main__":
    main()
