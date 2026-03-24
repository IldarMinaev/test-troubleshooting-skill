"""Workload threads: regular workers, deadlock generator, long-running query runner."""

import logging
import random
import threading
import time
import uuid

import psycopg2
import psycopg2.errors

import db

log = logging.getLogger(__name__)

# Preload SQL scripts
_SQL_CACHE = {}


def _get_sql(name):
    if name not in _SQL_CACHE:
        _SQL_CACHE[name] = db.load_sql(name)
    return _SQL_CACHE[name]


# ── Stats ──────────────────────────────────────────────────────────────

class Stats:
    def __init__(self):
        self._lock = threading.Lock()
        self._counts = {}
        self._errors = {}

    def record(self, workload, error=False):
        with self._lock:
            if error:
                self._errors[workload] = self._errors.get(workload, 0) + 1
            else:
                self._counts[workload] = self._counts.get(workload, 0) + 1

    def snapshot(self):
        with self._lock:
            return dict(self._counts), dict(self._errors)


_stats = Stats()


def get_stats():
    return _stats.snapshot()


# ── Weighted random selection ──────────────────────────────────────────

def _pick_workload(workload_mix):
    names = list(workload_mix.keys())
    weights = [workload_mix[n] for n in names]
    return random.choices(names, weights=weights, k=1)[0]


# ── Insert rate control ───────────────────────────────────────────────

def _calc_insert_sleep(insert_rate_mb_per_hour, insert_weight_ratio):
    """Calculate sleep between insert batches.

    Each batch: 100 rows * ~1KB = ~100KB = 0.1MB
    Target rate: INSERT_RATE_MB_PER_HOUR MB/h total across all workers.
    """
    if insert_weight_ratio <= 0:
        return 1.0
    batches_per_hour = insert_rate_mb_per_hour / 0.1
    effective_workers = max(1, insert_weight_ratio)
    batches_per_worker_per_hour = batches_per_hour / effective_workers
    if batches_per_worker_per_hour <= 0:
        return 60.0
    return 3600.0 / batches_per_worker_per_hour


# ── Individual workload executors ─────────────────────────────────────

def _run_insert(shutdown_event, sleep_seconds):
    """Insert a batch of 100 rows (~100KB)."""
    batch_id = str(uuid.uuid4())
    sql = _get_sql("insert_test_data")
    conn = db.get_conn()
    try:
        conn.autocommit = False
        with conn.cursor() as cur:
            cur.execute(sql, (batch_id,))
        conn.commit()
        _stats.record("insert")
    finally:
        db.put_conn(conn)
    shutdown_event.wait(timeout=sleep_seconds)


def _run_select(shutdown_event):
    """Full table scan on unindexed column."""
    sql = _get_sql("select_test_data")
    conn = db.get_conn()
    try:
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(sql)
        _stats.record("select")
    finally:
        db.put_conn(conn)


def _run_update(shutdown_event):
    """Update random rows."""
    sql = _get_sql("update_test_data")
    conn = db.get_conn()
    try:
        conn.autocommit = False
        with conn.cursor() as cur:
            cur.execute(sql)
        conn.commit()
        _stats.record("update")
    finally:
        db.put_conn(conn)


def _run_lock_contention(shutdown_event):
    """Hold row locks for a short period."""
    conn = db.get_conn()
    try:
        conn.autocommit = False
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM load_test_data "
                "WHERE id IN (SELECT id FROM load_test_data ORDER BY random() LIMIT 5) "
                "FOR UPDATE NOWAIT"
            )
            _stats.record("lock_contention")
            # Hold locks for 5-15 seconds
            shutdown_event.wait(timeout=random.uniform(5, 15))
        conn.rollback()
    except psycopg2.errors.LockNotAvailable:
        conn.rollback()
        log.debug("Lock not available (expected under contention)")
        _stats.record("lock_contention", error=True)
    finally:
        db.put_conn(conn)


def _run_temp_table_bloat(shutdown_event):
    """Create large temp table for memory pressure."""
    sql = _get_sql("temp_table_bloat")
    conn = db.get_conn()
    try:
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(sql)
        _stats.record("temp_table_bloat")
    finally:
        db.put_conn(conn)


def _run_connection_bloat(shutdown_event):
    """Hold a connection idle-in-transaction."""
    conn = db.get_conn()
    try:
        conn.autocommit = False
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
        _stats.record("connection_bloat")
        # Hold idle-in-transaction for 30-120 seconds
        shutdown_event.wait(timeout=random.uniform(30, 120))
        conn.rollback()
    finally:
        db.put_conn(conn)


# ── Worker thread ─────────────────────────────────────────────────────

def _worker_loop(worker_id, config, shutdown_event):
    """Main loop for a regular worker thread."""
    insert_total = sum(config.workload_mix.values())
    insert_weight = config.workload_mix.get("insert", 0)
    insert_ratio = (insert_weight / insert_total * config.worker_count) if insert_total > 0 else 0
    insert_sleep = _calc_insert_sleep(config.insert_rate_mb_per_hour, insert_ratio)

    log.info("Worker %d started (insert_sleep=%.1fs)", worker_id, insert_sleep)

    while not shutdown_event.is_set():
        workload = _pick_workload(config.workload_mix)
        try:
            if workload == "insert":
                _run_insert(shutdown_event, insert_sleep)
            elif workload == "select":
                _run_select(shutdown_event)
            elif workload == "update":
                _run_update(shutdown_event)
            elif workload == "lock_contention":
                _run_lock_contention(shutdown_event)
            elif workload == "temp_table_bloat":
                _run_temp_table_bloat(shutdown_event)
            elif workload == "connection_bloat":
                _run_connection_bloat(shutdown_event)
            else:
                log.warning("Unknown workload '%s', skipping", workload)
                shutdown_event.wait(timeout=1)
        except psycopg2.errors.DeadlockDetected:
            log.info("Worker %d: deadlock detected (expected)", worker_id)
            _stats.record(workload, error=True)
        except psycopg2.errors.QueryCanceled:
            log.debug("Worker %d: query canceled", worker_id)
            _stats.record(workload, error=True)
        except psycopg2.OperationalError as exc:
            log.warning("Worker %d: connection error: %s", worker_id, exc)
            _stats.record(workload, error=True)
            shutdown_event.wait(timeout=5)
        except Exception:
            log.exception("Worker %d: unexpected error in workload '%s'", worker_id, workload)
            _stats.record(workload, error=True)
            shutdown_event.wait(timeout=1)

    log.info("Worker %d stopped", worker_id)


# ── Deadlock generator ────────────────────────────────────────────────

def _deadlock_thread(conn, account_a, account_b, barrier, shutdown_event):
    """One side of the deadlock: lock account_a, then try account_b."""
    try:
        conn.autocommit = False
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE load_test_accounts SET balance = balance - 10, updated_at = now() "
                "WHERE account_id = %s",
                (account_a,),
            )
            barrier.wait(timeout=10)
            if shutdown_event.is_set():
                conn.rollback()
                return
            cur.execute(
                "UPDATE load_test_accounts SET balance = balance + 10, updated_at = now() "
                "WHERE account_id = %s",
                (account_b,),
            )
        conn.commit()
    except psycopg2.errors.DeadlockDetected:
        log.info("Deadlock detected (expected, this is the test)")
        conn.rollback()
        _stats.record("deadlock", error=True)
    except Exception:
        log.debug("Deadlock thread error", exc_info=True)
        try:
            conn.rollback()
        except Exception:
            pass
        _stats.record("deadlock", error=True)


def _deadlock_generator_loop(config, shutdown_event):
    """Periodically generate deadlocks between two accounts."""
    log.info("Deadlock generator started (interval=%ds)", config.deadlock_interval_seconds)

    while not shutdown_event.is_set():
        shutdown_event.wait(timeout=config.deadlock_interval_seconds)
        if shutdown_event.is_set():
            break

        # Pick two distinct random account IDs (1-100)
        id_a, id_b = random.sample(range(1, 101), 2)
        log.info("Generating deadlock between accounts %d and %d", id_a, id_b)

        barrier = threading.Barrier(2, timeout=15)
        conn_a = db.get_conn()
        conn_b = db.get_conn()

        t_a = threading.Thread(
            target=_deadlock_thread,
            args=(conn_a, id_a, id_b, barrier, shutdown_event),
            daemon=True,
        )
        t_b = threading.Thread(
            target=_deadlock_thread,
            args=(conn_b, id_b, id_a, barrier, shutdown_event),
            daemon=True,
        )
        t_a.start()
        t_b.start()
        t_a.join(timeout=30)
        t_b.join(timeout=30)

        db.put_conn(conn_a)
        db.put_conn(conn_b)
        _stats.record("deadlock")

    log.info("Deadlock generator stopped")


# ── Long-running query ────────────────────────────────────────────────

def _long_query_loop(config, shutdown_event):
    """Run long-running queries with statement_timeout."""
    log.info(
        "Long-running query thread started (duration=%ds)",
        config.long_query_duration_seconds,
    )
    timeout_ms = config.long_query_duration_seconds * 1000

    while not shutdown_event.is_set():
        conn = db.get_conn()
        try:
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(f"SET statement_timeout = '{timeout_ms}'")

                # Check table size to decide strategy
                cur.execute("SELECT count(*) FROM load_test_data")
                row_count = cur.fetchone()[0]

                if row_count > 500:
                    log.info("Running cross-join long query (table has %d rows)", row_count)
                    sql = _get_sql("long_running_query")
                    try:
                        cur.execute(sql)
                    except psycopg2.errors.QueryCanceled:
                        log.debug("Long query canceled by statement_timeout (expected)")
                else:
                    log.info("Table too small (%d rows), using pg_sleep fallback", row_count)
                    try:
                        cur.execute(f"SELECT pg_sleep({config.long_query_duration_seconds})")
                    except psycopg2.errors.QueryCanceled:
                        log.debug("pg_sleep canceled by statement_timeout (expected)")

                cur.execute("RESET statement_timeout")
            _stats.record("long_query")
        except psycopg2.OperationalError as exc:
            log.warning("Long query thread: connection error: %s", exc)
            _stats.record("long_query", error=True)
            shutdown_event.wait(timeout=5)
        except Exception:
            log.exception("Long query thread: unexpected error")
            _stats.record("long_query", error=True)
            shutdown_event.wait(timeout=1)
        finally:
            db.put_conn(conn)

        # Brief pause between long queries
        shutdown_event.wait(timeout=5)

    log.info("Long-running query thread stopped")


# ── Stats reporter ────────────────────────────────────────────────────

def _stats_reporter(shutdown_event):
    """Log workload stats every 60 seconds."""
    while not shutdown_event.is_set():
        shutdown_event.wait(timeout=60)
        if shutdown_event.is_set():
            break
        counts, errors = get_stats()
        log.info("Stats — completed: %s | errors: %s", counts, errors)


# ── Public API ────────────────────────────────────────────────────────

def start_all(config, shutdown_event):
    """Start all workload threads. Returns list of threads."""
    threads = []

    # Regular workers
    for i in range(config.worker_count):
        t = threading.Thread(
            target=_worker_loop,
            args=(i, config, shutdown_event),
            name=f"worker-{i}",
            daemon=True,
        )
        t.start()
        threads.append(t)

    # Deadlock generator
    t = threading.Thread(
        target=_deadlock_generator_loop,
        args=(config, shutdown_event),
        name="deadlock-gen",
        daemon=True,
    )
    t.start()
    threads.append(t)

    # Long-running query
    t = threading.Thread(
        target=_long_query_loop,
        args=(config, shutdown_event),
        name="long-query",
        daemon=True,
    )
    t.start()
    threads.append(t)

    # Stats reporter
    t = threading.Thread(
        target=_stats_reporter,
        args=(shutdown_event,),
        name="stats",
        daemon=True,
    )
    t.start()
    threads.append(t)

    log.info(
        "All workload threads started: %d workers + deadlock-gen + long-query + stats",
        config.worker_count,
    )
    return threads
