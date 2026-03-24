"""DBAAS API client — create/get database with exponential backoff retry."""

import logging
import time

import requests

log = logging.getLogger(__name__)

MAX_RETRIES = 10
INITIAL_BACKOFF = 2  # seconds


class DbaasError(Exception):
    pass


class DbaasClient:
    def __init__(self, base_url, username, password):
        self.base_url = base_url.rstrip("/")
        self.auth = (username, password)

    def ensure_database(self, namespace):
        """Create or retrieve the test database via DBAAS API.

        Returns dict with keys: host, port, name, username, password.
        """
        url = f"{self.base_url}/api/v3/dbaas/{namespace}/databases"
        payload = {
            "classifier": {
                "microserviceName": "my-business-app",
                "scope": "service",
                "namespace": namespace,
            },
            "type": "postgresql",
            "originService": "my-business-app",
        }

        backoff = INITIAL_BACKOFF
        last_error = None

        for attempt in range(1, MAX_RETRIES + 1):
            try:
                log.info("DBAAS PUT %s (attempt %d/%d)", url, attempt, MAX_RETRIES)
                resp = requests.put(url, json=payload, auth=self.auth, timeout=30)

                if resp.status_code in (200, 201):
                    data = resp.json()
                    conn = data.get("connectionProperties") or data
                    result = {
                        "host": conn["host"],
                        "port": int(conn.get("port", 5432)),
                        "name": conn["name"],
                        "username": conn["username"],
                        "password": conn["password"],
                    }
                    log.info(
                        "DBAAS database ready: host=%s port=%d dbname=%s user=%s",
                        result["host"],
                        result["port"],
                        result["name"],
                        result["username"],
                    )
                    return result

                last_error = f"HTTP {resp.status_code}: {resp.text[:200]}"
                log.warning("DBAAS request failed: %s", last_error)

            except requests.RequestException as exc:
                last_error = str(exc)
                log.warning("DBAAS request error: %s", last_error)

            if attempt < MAX_RETRIES:
                log.info("Retrying in %ds...", backoff)
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)

        raise DbaasError(f"Failed to provision database after {MAX_RETRIES} attempts: {last_error}")
