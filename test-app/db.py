"""Connection pool management and schema initialization."""

import logging
import os
import threading

import psycopg2
from psycopg2 import pool as pg_pool

log = logging.getLogger(__name__)

SQL_DIR = os.path.join(os.path.dirname(__file__), "sql")

_pool = None
_pool_lock = threading.Lock()


def _read_sql(filename):
    path = os.path.join(SQL_DIR, filename)
    with open(path) as f:
        return f.read()


def init_pool(db_params, pool_size):
    """Create the global ThreadedConnectionPool.

    Args:
        db_params: dict with host, port, name, username, password
        pool_size: max number of connections
    """
    global _pool
    dsn = (
        f"host={db_params['host']} "
        f"port={db_params['port']} "
        f"dbname={db_params['name']} "
        f"user={db_params['username']} "
        f"password={db_params['password']}"
    )
    log.info(
        "Creating connection pool: host=%s port=%d dbname=%s user=%s pool_size=%d",
        db_params["host"],
        db_params["port"],
        db_params["name"],
        db_params["username"],
        pool_size,
    )
    _pool = pg_pool.ThreadedConnectionPool(minconn=2, maxconn=pool_size, dsn=dsn)
    log.info("Connection pool created")


def init_schema():
    """Run schema.sql to create tables idempotently."""
    schema_sql = _read_sql("schema.sql")
    conn = get_conn()
    try:
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(schema_sql)
        log.info("Schema initialized")
    finally:
        put_conn(conn)


def get_conn():
    """Get a connection from the pool."""
    return _pool.getconn()


def put_conn(conn, close=False):
    """Return a connection to the pool."""
    try:
        _pool.putconn(conn, close=close)
    except Exception:
        log.debug("Error returning connection to pool", exc_info=True)


def close_pool():
    """Close all connections in the pool."""
    global _pool
    if _pool:
        log.info("Closing connection pool")
        _pool.closeall()
        _pool = None


def load_sql(name):
    """Load a SQL script by short name (without .sql extension)."""
    return _read_sql(f"{name}.sql")
