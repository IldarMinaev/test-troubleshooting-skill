"""Environment variable parsing with defaults and validation."""

import os
import sys


class Config:
    def __init__(self):
        # Required
        self.dbaas_url = self._require("DBAAS_URL")
        self.dbaas_user = self._require("DBAAS_USER")
        self.dbaas_password = self._require("DBAAS_PASSWORD")
        self.app_namespace = self._require("APP_NAMESPACE")

        # Optional with defaults
        self.worker_count = int(os.environ.get("WORKER_COUNT", "4"))
        self.insert_rate_mb_per_hour = float(os.environ.get("INSERT_RATE_MB_PER_HOUR", "100"))
        self.report_timeout_seconds = int(os.environ.get("REPORT_TIMEOUT_SECONDS", "300"))
        self.reconciliation_interval_seconds = int(os.environ.get("RECONCILIATION_INTERVAL_SECONDS", "600"))
        self.task_distribution = self._parse_task_distribution(
            os.environ.get(
                "TASK_DISTRIBUTION",
                "insert:40,select:30,update:15,inventory_audit:5,bulk_reconciliation:5,approval_hold:5",
            )
        )

        self._validate()

    @staticmethod
    def _require(name):
        value = os.environ.get(name)
        if not value:
            print(f"FATAL: required environment variable {name} is not set", file=sys.stderr)
            sys.exit(1)
        return value

    @staticmethod
    def _parse_task_distribution(raw):
        """Parse 'insert:40,select:30,...' into {name: weight} dict."""
        mix = {}
        for part in raw.split(","):
            part = part.strip()
            if ":" not in part:
                print(f"FATAL: invalid TASK_DISTRIBUTION entry '{part}', expected 'name:weight'", file=sys.stderr)
                sys.exit(1)
            name, weight_str = part.split(":", 1)
            mix[name.strip()] = int(weight_str.strip())
        return mix

    def _validate(self):
        if self.worker_count < 1:
            print("FATAL: WORKER_COUNT must be >= 1", file=sys.stderr)
            sys.exit(1)
        if self.insert_rate_mb_per_hour <= 0:
            print("FATAL: INSERT_RATE_MB_PER_HOUR must be > 0", file=sys.stderr)
            sys.exit(1)
        if not self.task_distribution:
            print("FATAL: TASK_DISTRIBUTION must not be empty", file=sys.stderr)
            sys.exit(1)
        total_weight = sum(self.task_distribution.values())
        if total_weight <= 0:
            print("FATAL: TASK_DISTRIBUTION total weight must be > 0", file=sys.stderr)
            sys.exit(1)
