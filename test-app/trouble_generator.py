"""Trouble Generator: Create realistic PostgreSQL issues for testing AI troubleshooting skills."""

import logging
import signal
import sys
import threading
import time
from enum import Enum
from typing import Dict, List, Optional, Set

from config import Config
from dbaas_client import DbaasClient, DbaasError
import db

log = logging.getLogger(__name__)


class Intensity(Enum):
    """Trouble intensity levels."""
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    EXTREME = "extreme"


class TroubleScenario:
    """Base class for trouble scenarios."""

    def __init__(self, name: str, description: str, skills: List[str]):
        self.name = name
        self.description = description
        self.skills = skills  # AI skills that should detect this
        self.active = False
        self.thread: Optional[threading.Thread] = None
        self.shutdown_event = threading.Event()

    def start(self, intensity: Intensity, shutdown_event: threading.Event):
        """Start the trouble scenario."""
        if self.active:
            log.warning("Scenario %s already active", self.name)
            return

        self.shutdown_event = shutdown_event
        self.active = True
        self.thread = threading.Thread(
            target=self._run,
            args=(intensity, shutdown_event),
            name=f"trouble-{self.name}",
            daemon=True
        )
        self.thread.start()
        log.info("Started trouble scenario: %s (intensity=%s)", self.name, intensity.value)

    def stop(self):
        """Stop the trouble scenario."""
        if not self.active:
            return

        self.active = False
        self.shutdown_event.set()
        if self.thread:
            self.thread.join(timeout=10)
        self.cleanup()
        log.info("Stopped trouble scenario: %s", self.name)

    def _run(self, intensity: Intensity, shutdown_event: threading.Event):
        """Override this method to implement the scenario logic."""
        raise NotImplementedError

    def cleanup(self):
        """Override this method to clean up resources."""
        pass


# ── Performance Trouble Scenarios ──────────────────────────────────────

class SlowQueriesScenario(TroubleScenario):
    """Generate slow-running queries via cross-joins."""

    def __init__(self):
        super().__init__(
            name="slow-queries",
            description="Long-running cross-join queries causing high CPU",
            skills=["postgresql-performance-check", "common-troubleshooting"]
        )

    def _run(self, intensity: Intensity, shutdown_event: threading.Event):
        # Intensity determines query duration and frequency
        config = {
            Intensity.LOW: {"duration_sec": 30, "frequency_sec": 60},
            Intensity.MEDIUM: {"duration_sec": 120, "frequency_sec": 30},
            Intensity.HIGH: {"duration_sec": 300, "frequency_sec": 15},
            Intensity.EXTREME: {"duration_sec": 600, "frequency_sec": 5}
        }[intensity]

        sql = db.load_sql("long_running_query")

        while not shutdown_event.is_set():
            conn = db.get_conn()
            try:
                conn.autocommit = True
                with conn.cursor() as cur:
                    # Set statement_timeout to allow query to run long
                    timeout_ms = config["duration_sec"] * 1000
                    cur.execute(f"SET statement_timeout = '{timeout_ms}'")

                    log.info("Executing slow query (duration=%ds)", config["duration_sec"])
                    start = time.time()
                    try:
                        cur.execute(sql)
                        elapsed = time.time() - start
                        log.info("Slow query completed in %.1fs", elapsed)
                    except Exception as e:
                        log.debug("Slow query error: %s", e)
                    finally:
                        cur.execute("RESET statement_timeout")
            finally:
                db.put_conn(conn)

            shutdown_event.wait(timeout=config["frequency_sec"])


class MissingIndexesScenario(TroubleScenario):
    """Full table scans on unindexed columns."""

    def __init__(self):
        super().__init__(
            name="missing-indexes",
            description="Sequential scans on large unindexed columns",
            skills=["postgresql-performance-check"]
        )

    def _run(self, intensity: Intensity, shutdown_event: threading.Event):
        # Query the unindexed 'data' column repeatedly
        sql = db.load_sql("select_test_data")

        config = {
            Intensity.LOW: {"workers": 1, "frequency_sec": 10},
            Intensity.MEDIUM: {"workers": 2, "frequency_sec": 5},
            Intensity.HIGH: {"workers": 4, "frequency_sec": 2},
            Intensity.EXTREME: {"workers": 8, "frequency_sec": 1}
        }[intensity]

        def worker():
            while not shutdown_event.is_set():
                conn = db.get_conn()
                try:
                    conn.autocommit = True
                    with conn.cursor() as cur:
                        cur.execute(sql)
                except Exception as e:
                    log.debug("Index scan error: %s", e)
                finally:
                    db.put_conn(conn)
                shutdown_event.wait(timeout=config["frequency_sec"])

        threads = []
        for i in range(config["workers"]):
            t = threading.Thread(target=worker, daemon=True)
            t.start()
            threads.append(t)

        for t in threads:
            t.join()


class LockContentionScenario(TroubleScenario):
    """Row-level lock contention."""

    def __init__(self):
        super().__init__(
            name="lock-contention",
            description="Multiple transactions competing for row locks",
            skills=["postgresql-performance-check"]
        )

    def _run(self, intensity: Intensity, shutdown_event: threading.Event):
        config = {
            Intensity.LOW: {"workers": 2, "hold_time_sec": 10, "frequency_sec": 20},
            Intensity.MEDIUM: {"workers": 4, "hold_time_sec": 30, "frequency_sec": 10},
            Intensity.HIGH: {"workers": 8, "hold_time_sec": 60, "frequency_sec": 5},
            Intensity.EXTREME: {"workers": 16, "hold_time_sec": 120, "frequency_sec": 2}
        }[intensity]

        sql = db.load_sql("lock_contention")

        def worker():
            while not shutdown_event.is_set():
                conn = db.get_conn()
                try:
                    conn.autocommit = False
                    with conn.cursor() as cur:
                        try:
                            cur.execute(sql)
                            log.debug("Lock acquired, holding for %ds", config["hold_time_sec"])
                            shutdown_event.wait(timeout=config["hold_time_sec"])
                            conn.commit()
                        except Exception as e:
                            conn.rollback()
                            log.debug("Lock contention: %s", e)
                except Exception:
                    pass
                finally:
                    db.put_conn(conn)
                shutdown_event.wait(timeout=config["frequency_sec"])

        threads = []
        for i in range(config["workers"]):
            t = threading.Thread(target=worker, daemon=True)
            t.start()
            threads.append(t)

        for t in threads:
            t.join()


class VacuumIssuesScenario(TroubleScenario):
    """Prevent autovacuum to create bloat."""

    def __init__(self):
        super().__init__(
            name="vacuum-issues",
            description="Table bloat from prevented autovacuum",
            skills=["postgresql-performance-check", "postgresql-storage-check"]
        )

    def _run(self, intensity: Intensity, shutdown_event: threading.Event):
        # Start a long-running transaction to prevent autovacuum
        # Then do lots of updates
        config = {
            Intensity.LOW: {"update_rate_sec": 10, "batch_size": 100},
            Intensity.MEDIUM: {"update_rate_sec": 5, "batch_size": 500},
            Intensity.HIGH: {"update_rate_sec": 2, "batch_size": 1000},
            Intensity.EXTREME: {"update_rate_sec": 1, "batch_size": 2000}
        }[intensity]

        # Hold a connection in transaction to block vacuum
        blocker_conn = db.get_conn()
        blocker_conn.autocommit = False
        with blocker_conn.cursor() as cur:
            cur.execute("SELECT 1")  # Start transaction
            log.info("Transaction started to block autovacuum")

        try:
            # Generate updates that create dead tuples
            update_sql = db.load_sql("update_test_data")
            while not shutdown_event.is_set():
                conn = db.get_conn()
                try:
                    conn.autocommit = False
                    with conn.cursor() as cur:
                        for _ in range(config["batch_size"]):
                            if shutdown_event.is_set():
                                break
                            cur.execute(update_sql)
                    conn.commit()
                    log.debug("Updated %d rows, creating dead tuples", config["batch_size"])
                except Exception as e:
                    conn.rollback()
                    log.debug("Update error: %s", e)
                finally:
                    db.put_conn(conn)

                shutdown_event.wait(timeout=config["update_rate_sec"])
        finally:
            blocker_conn.rollback()
            db.put_conn(blocker_conn)
            log.info("Released vacuum blocker transaction")


# ── Connection Trouble Scenarios ───────────────────────────────────────

class PoolExhaustionScenario(TroubleScenario):
    """Exhaust PgBouncer connection pool."""

    def __init__(self):
        super().__init__(
            name="pool-exhaustion",
            description="PgBouncer pool saturation",
            skills=["postgresql-connection-check", "common-troubleshooting"]
        )
        self.held_connections = []

    def _run(self, intensity: Intensity, shutdown_event: threading.Event):
        # Determine how many connections to hold based on intensity
        # This assumes pool size is known (e.g., 20)
        # We'll try to get pool info from pg_settings, or use a default

        config = {
            Intensity.LOW: {"fill_percent": 50, "hold_time_sec": 60},
            Intensity.MEDIUM: {"fill_percent": 80, "hold_time_sec": 120},
            Intensity.HIGH: {"fill_percent": 95, "hold_time_sec": 300},
            Intensity.EXTREME: {"fill_percent": 100, "hold_time_sec": 600}
        }[intensity]

        # Get max_connections to estimate safe connection count
        try:
            conn = db.get_conn()
            with conn.cursor() as cur:
                cur.execute("SHOW max_connections")
                max_conn = int(cur.fetchone()[0])
            db.put_conn(conn)

            # Assume PgBouncer pool is 20-30% of max_connections
            estimated_pool_size = max(20, int(max_conn * 0.25))
        except Exception:
            estimated_pool_size = 20  # Default fallback

        target_connections = int(estimated_pool_size * config["fill_percent"] / 100)
        log.info("Pool exhaustion: targeting %d connections (estimated pool: %d)",
                 target_connections, estimated_pool_size)

        # Acquire connections and hold them
        for i in range(target_connections):
            if shutdown_event.is_set():
                break
            try:
                conn = db.get_conn()
                conn.autocommit = False
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")  # Start transaction
                self.held_connections.append(conn)
                log.debug("Acquired connection %d/%d", i+1, target_connections)
            except Exception as e:
                log.warning("Failed to acquire connection %d: %s", i+1, e)
                break

        log.info("Holding %d connections for %ds",
                 len(self.held_connections), config["hold_time_sec"])
        shutdown_event.wait(timeout=config["hold_time_sec"])

    def cleanup(self):
        """Release all held connections."""
        for conn in self.held_connections:
            try:
                conn.rollback()
                db.put_conn(conn)
            except Exception:
                pass
        self.held_connections.clear()
        log.info("Released all held connections")


class IdleInTransactionScenario(TroubleScenario):
    """Connections stuck idle-in-transaction."""

    def __init__(self):
        super().__init__(
            name="idle-in-transaction",
            description="Connections idle in transaction",
            skills=["postgresql-connection-check", "postgresql-performance-check"]
        )

    def _run(self, intensity: Intensity, shutdown_event: threading.Event):
        config = {
            Intensity.LOW: {"connections": 2, "hold_time_sec": 120},
            Intensity.MEDIUM: {"connections": 5, "hold_time_sec": 300},
            Intensity.HIGH: {"connections": 10, "hold_time_sec": 600},
            Intensity.EXTREME: {"connections": 20, "hold_time_sec": 1200}
        }[intensity]

        sql = db.load_sql("connection_bloat")

        def worker(worker_id):
            while not shutdown_event.is_set():
                conn = db.get_conn()
                try:
                    conn.autocommit = False
                    with conn.cursor() as cur:
                        cur.execute(sql)
                    log.debug("Worker %d: idle-in-transaction for %ds",
                             worker_id, config["hold_time_sec"])
                    shutdown_event.wait(timeout=config["hold_time_sec"])
                    conn.rollback()
                except Exception as e:
                    log.debug("Worker %d error: %s", worker_id, e)
                finally:
                    db.put_conn(conn)

                shutdown_event.wait(timeout=10)

        threads = []
        for i in range(config["connections"]):
            t = threading.Thread(target=worker, args=(i,), daemon=True)
            t.start()
            threads.append(t)

        for t in threads:
            t.join()


# ── Storage Trouble Scenarios ──────────────────────────────────────────

class DiskFillScenario(TroubleScenario):
    """Fill disk with large data inserts."""

    def __init__(self):
        super().__init__(
            name="disk-fill",
            description="Rapid disk consumption via large inserts",
            skills=["postgresql-storage-check", "common-troubleshooting"]
        )

    def _run(self, intensity: Intensity, shutdown_event: threading.Event):
        # Insert large rows (1MB each) to quickly consume disk
        config = {
            Intensity.LOW: {"row_size_kb": 100, "batch_size": 10, "frequency_sec": 60},
            Intensity.MEDIUM: {"row_size_kb": 500, "batch_size": 20, "frequency_sec": 30},
            Intensity.HIGH: {"row_size_kb": 1000, "batch_size": 50, "frequency_sec": 10},
            Intensity.EXTREME: {"row_size_kb": 2000, "batch_size": 100, "frequency_sec": 5}
        }[intensity]

        while not shutdown_event.is_set():
            conn = db.get_conn()
            try:
                conn.autocommit = False
                with conn.cursor() as cur:
                    # Create large data payload
                    large_data = 'x' * (config["row_size_kb"] * 1024)

                    for i in range(config["batch_size"]):
                        if shutdown_event.is_set():
                            break
                        cur.execute(
                            "INSERT INTO load_test_data (batch_id, category, status, padding, created_at) "
                            "VALUES (%s, %s, %s, %s, now())",
                            (f"disk-fill-{time.time()}", "disk-fill", "active", large_data)
                        )
                    conn.commit()

                    size_mb = (config["row_size_kb"] * config["batch_size"]) / 1024
                    log.info("Inserted %.1f MB of data", size_mb)
            except Exception as e:
                conn.rollback()
                log.warning("Disk fill error: %s", e)
                # If we hit disk full, stop trying
                if "disk" in str(e).lower() or "space" in str(e).lower():
                    log.error("Disk full detected, stopping scenario")
                    break
            finally:
                db.put_conn(conn)

            shutdown_event.wait(timeout=config["frequency_sec"])


class WALAccumulationScenario(TroubleScenario):
    """Create inactive replication slot to prevent WAL cleanup."""

    def __init__(self):
        super().__init__(
            name="wal-accumulation",
            description="WAL files accumulate from inactive replication slot",
            skills=["postgresql-storage-check", "postgresql-health-check"]
        )
        self.slot_name = None

    def _run(self, intensity: Intensity, shutdown_event: threading.Event):
        # This requires superuser or replication role
        # We'll try to create a slot, but it may fail with permissions

        slot_name = f"trouble_slot_{int(time.time())}"

        try:
            conn = db.get_conn()
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT pg_create_physical_replication_slot(%s)",
                    (slot_name,)
                )
                self.slot_name = slot_name
                log.info("Created inactive replication slot: %s", slot_name)

            db.put_conn(conn)

            # Generate write load to create WAL files
            config = {
                Intensity.LOW: {"write_rate_sec": 10},
                Intensity.MEDIUM: {"write_rate_sec": 5},
                Intensity.HIGH: {"write_rate_sec": 2},
                Intensity.EXTREME: {"write_rate_sec": 1}
            }[intensity]

            update_sql = db.load_sql("update_test_data")
            while not shutdown_event.is_set():
                conn = db.get_conn()
                try:
                    conn.autocommit = False
                    with conn.cursor() as cur:
                        for _ in range(100):
                            cur.execute(update_sql)
                    conn.commit()
                except Exception:
                    conn.rollback()
                finally:
                    db.put_conn(conn)

                shutdown_event.wait(timeout=config["write_rate_sec"])

        except Exception as e:
            log.warning("WAL accumulation scenario failed (may need superuser): %s", e)
            # Fall back to just generating writes without slot
            shutdown_event.wait(timeout=300)

    def cleanup(self):
        """Drop the replication slot."""
        if not self.slot_name:
            return

        try:
            conn = db.get_conn()
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT pg_drop_replication_slot(%s)",
                    (self.slot_name,)
                )
            db.put_conn(conn)
            log.info("Dropped replication slot: %s", self.slot_name)
        except Exception as e:
            log.warning("Failed to drop replication slot: %s", e)


# ── Scenario Registry ──────────────────────────────────────────────────

SCENARIO_REGISTRY: Dict[str, type] = {
    # Performance
    "slow-queries": SlowQueriesScenario,
    "missing-indexes": MissingIndexesScenario,
    "lock-contention": LockContentionScenario,
    "vacuum-issues": VacuumIssuesScenario,

    # Connections
    "pool-exhaustion": PoolExhaustionScenario,
    "idle-in-transaction": IdleInTransactionScenario,

    # Storage
    "disk-fill": DiskFillScenario,
    "wal-accumulation": WALAccumulationScenario,
}


class TroubleManager:
    """Manages trouble scenarios lifecycle."""

    def __init__(self):
        self.scenarios: Dict[str, TroubleScenario] = {}
        self.shutdown_event = threading.Event()
        self._lock = threading.Lock()

    def register_scenarios(self, scenario_names: List[str]):
        """Register scenarios by name."""
        for name in scenario_names:
            if name not in SCENARIO_REGISTRY:
                log.warning("Unknown scenario: %s", name)
                continue
            if name in self.scenarios:
                log.warning("Scenario already registered: %s", name)
                continue

            scenario_class = SCENARIO_REGISTRY[name]
            self.scenarios[name] = scenario_class()
            log.info("Registered scenario: %s", name)

    def start_scenario(self, name: str, intensity: Intensity):
        """Start a trouble scenario."""
        with self._lock:
            if name not in self.scenarios:
                log.error("Scenario not registered: %s", name)
                return False

            scenario = self.scenarios[name]
            scenario.start(intensity, self.shutdown_event)
            return True

    def stop_scenario(self, name: str):
        """Stop a trouble scenario."""
        with self._lock:
            if name not in self.scenarios:
                log.error("Scenario not registered: %s", name)
                return False

            scenario = self.scenarios[name]
            scenario.stop()
            return True

    def stop_all(self):
        """Stop all active scenarios."""
        self.shutdown_event.set()
        with self._lock:
            for scenario in self.scenarios.values():
                if scenario.active:
                    scenario.stop()

    def list_active(self) -> List[str]:
        """List active scenario names."""
        with self._lock:
            return [name for name, scenario in self.scenarios.items() if scenario.active]

    def list_available(self) -> List[str]:
        """List all available scenario names."""
        return list(SCENARIO_REGISTRY.keys())
