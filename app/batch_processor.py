"""Batch processing jobs for inventory service."""

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


class LoadLevel(Enum):
    """Processing load levels."""
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    EXTREME = "extreme"


class BatchJob:
    """Base class for batch jobs."""

    def __init__(self, name: str, description: str, tags: List[str]):
        self.name = name
        self.description = description
        self.tags = tags  # processing tags
        self.active = False
        self.thread: Optional[threading.Thread] = None
        self.shutdown_event = threading.Event()

    def start(self, intensity: LoadLevel, shutdown_event: threading.Event):
        """Start the batch job."""
        if self.active:
            log.warning("Job %s already running", self.name)
            return

        self.shutdown_event = shutdown_event
        self.active = True
        self.thread = threading.Thread(
            target=self._run,
            args=(intensity, shutdown_event),
            name=f"job-{self.name}",
            daemon=True
        )
        self.thread.start()
        log.info("Started batch job: %s (intensity=%s)", self.name, intensity.value)

    def stop(self):
        """Stop the batch job."""
        if not self.active:
            return

        self.active = False
        self.shutdown_event.set()
        if self.thread:
            self.thread.join(timeout=10)
        self.cleanup()
        log.info("Stopped batch job: %s", self.name)

    def _run(self, intensity: LoadLevel, shutdown_event: threading.Event):
        """Override this method to implement the job logic."""
        raise NotImplementedError

    def cleanup(self):
        """Override this method to clean up resources."""
        pass


# ── Performance Jobs ────────────────────────────────────────────────────

class ReportGenerationJob(BatchJob):
    """Generate report queries via cross-joins."""

    def __init__(self):
        super().__init__(
            name="report-generation",
            description="Long-running analytical queries for report generation",
            tags=["performance", "queries"]
        )

    def _run(self, intensity: LoadLevel, shutdown_event: threading.Event):
        # Intensity determines query duration and frequency
        config = {
            LoadLevel.LOW: {"duration_sec": 30, "frequency_sec": 60},
            LoadLevel.MEDIUM: {"duration_sec": 120, "frequency_sec": 30},
            LoadLevel.HIGH: {"duration_sec": 300, "frequency_sec": 15},
            LoadLevel.EXTREME: {"duration_sec": 600, "frequency_sec": 5}
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


class DataExportJob(BatchJob):
    """Full table scans on unindexed columns."""

    def __init__(self):
        super().__init__(
            name="data-export",
            description="Full data export with sequential scans",
            tags=["performance", "export"]
        )

    def _run(self, intensity: LoadLevel, shutdown_event: threading.Event):
        # Query the unindexed 'data' column repeatedly
        sql = db.load_sql("search_inventory")

        config = {
            LoadLevel.LOW: {"workers": 1, "frequency_sec": 10},
            LoadLevel.MEDIUM: {"workers": 2, "frequency_sec": 5},
            LoadLevel.HIGH: {"workers": 4, "frequency_sec": 2},
            LoadLevel.EXTREME: {"workers": 8, "frequency_sec": 1}
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


class BatchReconciliationJob(BatchJob):
    """Batch reconciliation with row-level locking."""

    def __init__(self):
        super().__init__(
            name="batch-reconciliation",
            description="Batch reconciliation with row-level locking",
            tags=["performance", "reconciliation"]
        )

    def _run(self, intensity: LoadLevel, shutdown_event: threading.Event):
        config = {
            LoadLevel.LOW: {"workers": 2, "hold_time_sec": 10, "frequency_sec": 20},
            LoadLevel.MEDIUM: {"workers": 4, "hold_time_sec": 30, "frequency_sec": 10},
            LoadLevel.HIGH: {"workers": 8, "hold_time_sec": 60, "frequency_sec": 5},
            LoadLevel.EXTREME: {"workers": 16, "hold_time_sec": 120, "frequency_sec": 2}
        }[intensity]

        sql = db.load_sql("inventory_audit")

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
                            log.debug("Reconciliation row locked: %s", e)
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


class DataArchivalJob(BatchJob):
    """Data archival with high update throughput."""

    def __init__(self):
        super().__init__(
            name="data-archival",
            description="Data archival with high update throughput",
            tags=["performance", "storage"]
        )

    def _run(self, intensity: LoadLevel, shutdown_event: threading.Event):
        # Start a long-running transaction to hold a consistent snapshot
        # Then do lots of updates
        config = {
            LoadLevel.LOW: {"update_rate_sec": 10, "batch_size": 100},
            LoadLevel.MEDIUM: {"update_rate_sec": 5, "batch_size": 500},
            LoadLevel.HIGH: {"update_rate_sec": 2, "batch_size": 1000},
            LoadLevel.EXTREME: {"update_rate_sec": 1, "batch_size": 2000}
        }[intensity]

        # Hold a connection in transaction for archival snapshot
        blocker_conn = db.get_conn()
        blocker_conn.autocommit = False
        with blocker_conn.cursor() as cur:
            cur.execute("SELECT 1")  # Start transaction
            log.info("Archival snapshot transaction started")

        try:
            # Generate updates that create dead tuples
            update_sql = db.load_sql("update_inventory")
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
                    log.debug("Archived %d rows", config["batch_size"])
                except Exception as e:
                    conn.rollback()
                    log.debug("Update error: %s", e)
                finally:
                    db.put_conn(conn)

                shutdown_event.wait(timeout=config["update_rate_sec"])
        finally:
            blocker_conn.rollback()
            db.put_conn(blocker_conn)
            log.info("Released archival snapshot transaction")


# ── Connection Jobs ─────────────────────────────────────────────────────

class ParallelImportJob(BatchJob):
    """Parallel data import with high connection usage."""

    def __init__(self):
        super().__init__(
            name="parallel-import",
            description="Parallel data import with high connection usage",
            tags=["connections", "import"]
        )
        self.held_connections = []

    def _run(self, intensity: LoadLevel, shutdown_event: threading.Event):
        # Determine how many connections to hold based on intensity
        # This assumes pool size is known (e.g., 20)
        # We'll try to get pool info from pg_settings, or use a default

        config = {
            LoadLevel.LOW: {"fill_percent": 50, "hold_time_sec": 60},
            LoadLevel.MEDIUM: {"fill_percent": 80, "hold_time_sec": 120},
            LoadLevel.HIGH: {"fill_percent": 95, "hold_time_sec": 300},
            LoadLevel.EXTREME: {"fill_percent": 100, "hold_time_sec": 600}
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
        log.info("Allocating worker connections: %d (estimated pool: %d)",
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

        log.info("Workers allocated, processing batch (estimated %ds)",
                 config["hold_time_sec"])
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


class ApprovalWorkflowJob(BatchJob):
    """Approval workflow with held transactions."""

    def __init__(self):
        super().__init__(
            name="approval-workflow",
            description="Approval workflow with held transactions",
            tags=["connections", "workflow"]
        )

    def _run(self, intensity: LoadLevel, shutdown_event: threading.Event):
        config = {
            LoadLevel.LOW: {"connections": 2, "hold_time_sec": 120},
            LoadLevel.MEDIUM: {"connections": 5, "hold_time_sec": 300},
            LoadLevel.HIGH: {"connections": 10, "hold_time_sec": 600},
            LoadLevel.EXTREME: {"connections": 20, "hold_time_sec": 1200}
        }[intensity]

        sql = db.load_sql("approval_hold")

        def worker(worker_id):
            while not shutdown_event.is_set():
                conn = db.get_conn()
                try:
                    conn.autocommit = False
                    with conn.cursor() as cur:
                        cur.execute(sql)
                    log.debug("Worker %d: awaiting approval (%ds timeout)",
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


# ── Storage Jobs ────────────────────────────────────────────────────────

class DataMigrationJob(BatchJob):
    """Data migration with bulk inserts."""

    def __init__(self):
        super().__init__(
            name="data-migration",
            description="Data migration with bulk inserts",
            tags=["storage", "migration"]
        )

    def _run(self, intensity: LoadLevel, shutdown_event: threading.Event):
        # Insert large rows (1MB each) to quickly consume disk
        config = {
            LoadLevel.LOW: {"row_size_kb": 100, "batch_size": 10, "frequency_sec": 60},
            LoadLevel.MEDIUM: {"row_size_kb": 500, "batch_size": 20, "frequency_sec": 30},
            LoadLevel.HIGH: {"row_size_kb": 1000, "batch_size": 50, "frequency_sec": 10},
            LoadLevel.EXTREME: {"row_size_kb": 2000, "batch_size": 100, "frequency_sec": 5}
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
                            "INSERT INTO inventory_items (batch_id, category, status, padding, created_at) "
                            "VALUES (%s, %s, %s, %s, now())",
                            (f"migration-{time.time()}", "migration", "active", large_data)
                        )
                    conn.commit()

                    size_mb = (config["row_size_kb"] * config["batch_size"]) / 1024
                    log.info("Inserted %.1f MB of data", size_mb)
            except Exception as e:
                conn.rollback()
                log.warning("Migration insert error: %s", e)
                # If we hit disk full, stop trying
                if "disk" in str(e).lower() or "space" in str(e).lower():
                    log.error("Disk full detected, stopping migration")
                    break
            finally:
                db.put_conn(conn)

            shutdown_event.wait(timeout=config["frequency_sec"])


class ReplicationSetupJob(BatchJob):
    """Create inactive replication slot to prevent WAL cleanup."""

    def __init__(self):
        super().__init__(
            name="replication-setup",
            description="Replication setup with write-ahead log management",
            tags=["storage", "replication"]
        )
        self.slot_name = None

    def _run(self, intensity: LoadLevel, shutdown_event: threading.Event):
        # This requires superuser or replication role
        # We'll try to create a slot, but it may fail with permissions

        slot_name = f"sync_slot_{int(time.time())}"

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
                LoadLevel.LOW: {"write_rate_sec": 10},
                LoadLevel.MEDIUM: {"write_rate_sec": 5},
                LoadLevel.HIGH: {"write_rate_sec": 2},
                LoadLevel.EXTREME: {"write_rate_sec": 1}
            }[intensity]

            update_sql = db.load_sql("update_inventory")
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
            log.warning("Replication setup failed (may need superuser): %s", e)
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


# ── Job Registry ────────────────────────────────────────────────────────

JOB_REGISTRY: Dict[str, type] = {
    # Performance
    "report-generation": ReportGenerationJob,
    "data-export": DataExportJob,
    "batch-reconciliation": BatchReconciliationJob,
    "data-archival": DataArchivalJob,

    # Connections
    "parallel-import": ParallelImportJob,
    "approval-workflow": ApprovalWorkflowJob,

    # Storage
    "data-migration": DataMigrationJob,
    "replication-setup": ReplicationSetupJob,
}


class JobScheduler:
    """Manages batch job lifecycle."""

    def __init__(self):
        self.jobs: Dict[str, BatchJob] = {}
        self.shutdown_event = threading.Event()
        self._lock = threading.Lock()

    def register_jobs(self, job_names: List[str]):
        """Register jobs by name."""
        for name in job_names:
            if name not in JOB_REGISTRY:
                log.warning("Unknown job: %s", name)
                continue
            if name in self.jobs:
                log.warning("Job already registered: %s", name)
                continue

            job_class = JOB_REGISTRY[name]
            self.jobs[name] = job_class()
            log.info("Registered job: %s", name)

    def start_job(self, name: str, intensity: LoadLevel):
        """Start a batch job."""
        with self._lock:
            if name not in self.jobs:
                log.error("Job not registered: %s", name)
                return False

            job = self.jobs[name]
            job.start(intensity, self.shutdown_event)
            return True

    def stop_job(self, name: str):
        """Stop a batch job."""
        with self._lock:
            if name not in self.jobs:
                log.error("Job not registered: %s", name)
                return False

            job = self.jobs[name]
            job.stop()
            return True

    def stop_all(self):
        """Stop all active jobs."""
        self.shutdown_event.set()
        with self._lock:
            for job in self.jobs.values():
                if job.active:
                    job.stop()

    def list_active(self) -> List[str]:
        """List active job names."""
        with self._lock:
            return [name for name, job in self.jobs.items() if job.active]

    def list_available(self) -> List[str]:
        """List all available job names."""
        return list(JOB_REGISTRY.keys())
