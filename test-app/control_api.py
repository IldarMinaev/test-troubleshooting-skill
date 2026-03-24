"""HTTP API for runtime control of trouble scenarios."""

import logging
from typing import Dict, List

try:
    from flask import Flask, jsonify, request
    FLASK_AVAILABLE = True
except ImportError:
    FLASK_AVAILABLE = False

from trouble_generator import TroubleManager, Intensity, SCENARIO_REGISTRY

log = logging.getLogger(__name__)


class ControlAPI:
    """HTTP API for controlling trouble scenarios at runtime."""

    def __init__(self, manager: TroubleManager):
        if not FLASK_AVAILABLE:
            raise ImportError("Flask is required for Control API. Install with: pip install flask")

        self.manager = manager
        self.app = Flask(__name__)
        self._setup_routes()

    def _setup_routes(self):
        """Setup Flask routes."""

        @self.app.route("/health", methods=["GET"])
        def health():
            """Health check endpoint."""
            return jsonify({"status": "healthy"})

        @self.app.route("/api/troubles/catalog", methods=["GET"])
        def catalog():
            """Get catalog of all available trouble scenarios."""
            scenarios = []
            for name, scenario_class in SCENARIO_REGISTRY.items():
                scenario = scenario_class()
                scenarios.append({
                    "name": name,
                    "description": scenario.description,
                    "detectable_by": scenario.skills
                })
            return jsonify({"scenarios": scenarios})

        @self.app.route("/api/troubles/active", methods=["GET"])
        def active():
            """List currently active trouble scenarios."""
            active_scenarios = self.manager.list_active()
            return jsonify({"active": active_scenarios, "count": len(active_scenarios)})

        @self.app.route("/api/troubles/available", methods=["GET"])
        def available():
            """List all registered (available to start) scenarios."""
            available_scenarios = list(self.manager.scenarios.keys())
            return jsonify({"available": available_scenarios, "count": len(available_scenarios)})

        @self.app.route("/api/troubles/enable", methods=["POST"])
        def enable():
            """Enable a trouble scenario.

            Request body:
            {
                "scenario": "slow-queries",
                "intensity": "high"  # optional, defaults to "medium"
            }
            """
            data = request.get_json()
            if not data or "scenario" not in data:
                return jsonify({"error": "Missing 'scenario' in request body"}), 400

            scenario_name = data["scenario"]
            intensity_str = data.get("intensity", "medium")

            try:
                intensity = Intensity(intensity_str.lower())
            except ValueError:
                return jsonify({
                    "error": f"Invalid intensity '{intensity_str}'. "
                             f"Valid values: low, medium, high, extreme"
                }), 400

            # Register scenario if not already registered
            if scenario_name not in self.manager.scenarios:
                if scenario_name not in SCENARIO_REGISTRY:
                    return jsonify({"error": f"Unknown scenario '{scenario_name}'"}), 404

                self.manager.register_scenarios([scenario_name])

            # Start the scenario
            success = self.manager.start_scenario(scenario_name, intensity)
            if not success:
                return jsonify({"error": f"Failed to start scenario '{scenario_name}'"}), 500

            log.info("API: Enabled scenario %s (intensity=%s)", scenario_name, intensity_str)
            return jsonify({
                "status": "enabled",
                "scenario": scenario_name,
                "intensity": intensity_str
            })

        @self.app.route("/api/troubles/disable", methods=["POST"])
        def disable():
            """Disable a trouble scenario.

            Request body:
            {
                "scenario": "slow-queries"
            }
            """
            data = request.get_json()
            if not data or "scenario" not in data:
                return jsonify({"error": "Missing 'scenario' in request body"}), 400

            scenario_name = data["scenario"]

            success = self.manager.stop_scenario(scenario_name)
            if not success:
                return jsonify({"error": f"Failed to stop scenario '{scenario_name}'"}), 500

            log.info("API: Disabled scenario %s", scenario_name)
            return jsonify({
                "status": "disabled",
                "scenario": scenario_name
            })

        @self.app.route("/api/troubles/disable-all", methods=["POST"])
        def disable_all():
            """Disable all active trouble scenarios."""
            active_before = self.manager.list_active()
            self.manager.stop_all()

            log.info("API: Disabled all scenarios (%d total)", len(active_before))
            return jsonify({
                "status": "all_disabled",
                "stopped": active_before,
                "count": len(active_before)
            })

        @self.app.route("/api/emergency-stop", methods=["POST"])
        def emergency_stop():
            """Emergency stop - disable all scenarios immediately."""
            log.warning("API: Emergency stop triggered!")
            active_before = self.manager.list_active()
            self.manager.stop_all()

            return jsonify({
                "status": "emergency_stop_complete",
                "stopped": active_before,
                "count": len(active_before)
            })

    def run(self, host="0.0.0.0", port=8080):
        """Run the Flask API server."""
        log.info("Starting Control API on %s:%d", host, port)
        self.app.run(host=host, port=port, debug=False, threaded=True)


# Standalone mode for testing
if __name__ == "__main__":
    from trouble_generator import TroubleManager

    # Create a manager with all scenarios registered
    manager = TroubleManager()
    manager.register_scenarios(list(SCENARIO_REGISTRY.keys()))

    # Start API
    api = ControlAPI(manager)
    api.run()
