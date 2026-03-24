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
        self.long_query_duration_seconds = int(os.environ.get("LONG_QUERY_DURATION_SECONDS", "300"))
        self.deadlock_interval_seconds = int(os.environ.get("DEADLOCK_INTERVAL_SECONDS", "600"))
        self.workload_mix = self._parse_workload_mix(
            os.environ.get(
                "WORKLOAD_MIX",
                "insert:40,select:30,update:15,lock_contention:5,temp_table_bloat:5,connection_bloat:5",
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
    def _parse_workload_mix(raw):
        """Parse 'insert:40,select:30,...' into {name: weight} dict."""
        mix = {}
        for part in raw.split(","):
            part = part.strip()
            if ":" not in part:
                print(f"FATAL: invalid WORKLOAD_MIX entry '{part}', expected 'name:weight'", file=sys.stderr)
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
        if not self.workload_mix:
            print("FATAL: WORKLOAD_MIX must not be empty", file=sys.stderr)
            sys.exit(1)
        total_weight = sum(self.workload_mix.values())
        if total_weight <= 0:
            print("FATAL: WORKLOAD_MIX total weight must be > 0", file=sys.stderr)
            sys.exit(1)
