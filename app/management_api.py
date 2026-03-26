"""Management API for batch job control."""

import logging
from typing import Dict, List

try:
    from flask import Flask, jsonify, request
    FLASK_AVAILABLE = True
except ImportError:
    FLASK_AVAILABLE = False

from batch_processor import JobScheduler, LoadLevel, JOB_REGISTRY

log = logging.getLogger(__name__)


class ManagementAPI:
    """HTTP API for managing batch jobs at runtime."""

    def __init__(self, scheduler: JobScheduler):
        if not FLASK_AVAILABLE:
            raise ImportError("Flask is required for Management API. Install with: pip install flask")

        self.scheduler = scheduler
        self.app = Flask(__name__)
        self._setup_routes()

    def _setup_routes(self):
        """Setup Flask routes."""

        @self.app.route("/health", methods=["GET"])
        def health():
            """Health check endpoint."""
            return jsonify({"status": "healthy"})

        @self.app.route("/api/jobs/catalog", methods=["GET"])
        def catalog():
            """Get catalog of all available batch jobs."""
            jobs = []
            for name, job_class in JOB_REGISTRY.items():
                job = job_class()
                jobs.append({
                    "name": name,
                    "description": job.description,
                    "tags": job.tags
                })
            return jsonify({"jobs": jobs})

        @self.app.route("/api/jobs/active", methods=["GET"])
        def active():
            """List currently active batch jobs."""
            active_jobs = self.scheduler.list_active()
            return jsonify({"active": active_jobs, "count": len(active_jobs)})

        @self.app.route("/api/jobs/available", methods=["GET"])
        def available():
            """List all registered (available to start) jobs."""
            available_jobs = list(self.scheduler.jobs.keys())
            return jsonify({"available": available_jobs, "count": len(available_jobs)})

        @self.app.route("/api/jobs/start", methods=["POST"])
        def enable():
            """Start a batch job.

            Request body:
            {
                "job": "batch-export",
                "load_level": "high"  # optional, defaults to "medium"
            }
            """
            data = request.get_json()
            if not data or "job" not in data:
                return jsonify({"error": "Missing 'job' in request body"}), 400

            job_name = data["job"]
            load_level_str = data.get("load_level", "medium")

            try:
                load_level = LoadLevel(load_level_str.lower())
            except ValueError:
                return jsonify({
                    "error": f"Invalid load_level '{load_level_str}'. "
                             f"Valid values: low, medium, high, extreme"
                }), 400

            # Register job if not already registered
            if job_name not in self.scheduler.jobs:
                if job_name not in JOB_REGISTRY:
                    return jsonify({"error": f"Unknown job '{job_name}'"}), 404

                self.scheduler.register_jobs([job_name])

            # Start the job
            success = self.scheduler.start_job(job_name, load_level)
            if not success:
                return jsonify({"error": f"Failed to start job '{job_name}'"}), 500

            log.info("API: Started job %s (load_level=%s)", job_name, load_level_str)
            return jsonify({
                "status": "started",
                "job": job_name,
                "load_level": load_level_str
            })

        @self.app.route("/api/jobs/stop", methods=["POST"])
        def disable():
            """Stop a batch job.

            Request body:
            {
                "job": "batch-export"
            }
            """
            data = request.get_json()
            if not data or "job" not in data:
                return jsonify({"error": "Missing 'job' in request body"}), 400

            job_name = data["job"]

            success = self.scheduler.stop_job(job_name)
            if not success:
                return jsonify({"error": f"Failed to stop job '{job_name}'"}), 500

            log.info("API: Stopped job %s", job_name)
            return jsonify({
                "status": "stopped",
                "job": job_name
            })

        @self.app.route("/api/jobs/stop-all", methods=["POST"])
        def disable_all():
            """Stop all active batch jobs."""
            active_before = self.scheduler.list_active()
            self.scheduler.stop_all()

            log.info("API: Stopped all jobs (%d total)", len(active_before))
            return jsonify({
                "status": "all_stopped",
                "stopped": active_before,
                "count": len(active_before)
            })

        @self.app.route("/api/maintenance/shutdown", methods=["POST"])
        def emergency_stop():
            """Maintenance shutdown - stop all jobs immediately."""
            log.warning("API: Maintenance shutdown triggered!")
            active_before = self.scheduler.list_active()
            self.scheduler.stop_all()

            return jsonify({
                "status": "shutdown_complete",
                "stopped": active_before,
                "count": len(active_before)
            })

    def run(self, host="0.0.0.0", port=8080):
        """Run the Flask API server."""
        log.info("Starting Management API on %s:%d", host, port)
        self.app.run(host=host, port=port, debug=False, threaded=True)


# Standalone mode for testing
if __name__ == "__main__":
    from batch_processor import JobScheduler, JOB_REGISTRY

    # Create a scheduler with all jobs registered
    scheduler = JobScheduler()
    scheduler.register_jobs(list(JOB_REGISTRY.keys()))

    # Start API
    api = ManagementAPI(scheduler)
    api.run()
