"""A small notes service used to show off the deployment setup around it.

Endpoints
  GET  /          hit counter stored in Postgres, shows which replica answered
  GET  /notes     latest 20 notes
  POST /notes     {"text": "..."} adds a note
  GET  /healthz   liveness: is this process OK? (does NOT touch the database)
  GET  /readyz    readiness: can this replica reach the database?
  GET  /metrics   Prometheus metrics
  POST /admin/*   crash / sicken / heal, only when ENABLE_CHAOS=true (demo only)
"""
import json
import logging
import os
import signal
import socket
import sys
import threading
import time

import psycopg
from flask import Flask, Response, g, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

HOSTNAME = socket.gethostname()
log = logging.getLogger("app")

REQUESTS = Counter("http_requests_total", "HTTP requests", ["method", "endpoint", "status"])
LATENCY = Histogram("http_request_duration_seconds", "Request latency in seconds", ["endpoint"])
DB_ERRORS = Counter("db_errors_total", "Failed database operations")
APP_INFO = Gauge("app_info", "Build info (value is always 1)", ["version", "instance"])

SCHEMA = [
    (
        "CREATE TABLE IF NOT EXISTS notes ("
        " id SERIAL PRIMARY KEY, text TEXT NOT NULL,"
        " created_at TIMESTAMPTZ NOT NULL DEFAULT now())"
    ),
    "CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, n BIGINT NOT NULL)",
]
QUIET_PATHS = {"/healthz", "/metrics"}  # polled constantly, would drown the logs


class JsonFormatter(logging.Formatter):
    """One JSON object per line so Loki/Grafana can filter on fields."""

    def format(self, record):
        data = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "msg": record.getMessage(),
            "instance": HOSTNAME,
        }
        data.update(getattr(record, "fields", {}))
        if record.exc_info:
            data["exc"] = self.formatException(record.exc_info)
        return json.dumps(data)


def setup_logging():
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())


def create_app(config=None):
    cfg = {
        "DATABASE_URL": os.environ.get("DATABASE_URL"),
        "ENABLE_CHAOS": os.environ.get("ENABLE_CHAOS", "false").lower() == "true",
        "VERSION": os.environ.get("APP_VERSION", "dev"),
        "CONNECT": None,  # tests inject a fake connection factory here
    }
    cfg.update(config or {})

    # Fail fast with a message a human can act on (the "missing env vars" problem).
    if not cfg["DATABASE_URL"] and not cfg["CONNECT"]:
        raise RuntimeError("DATABASE_URL is not set. Copy .env.example to .env and fill it in.")

    def connect():
        if cfg["CONNECT"]:
            return cfg["CONNECT"]()
        return psycopg.connect(cfg["DATABASE_URL"], connect_timeout=3)

    app = Flask(__name__)
    state = {"schema_ready": False, "sick": False}
    schema_lock = threading.Lock()
    APP_INFO.labels(version=cfg["VERSION"], instance=HOSTNAME).set(1)

    def ensure_schema():
        """Create tables on first use. Re-runs after any DB error, so a freshly
        recreated database heals itself without restarting the app."""
        if state["schema_ready"]:
            return
        with schema_lock:
            if state["schema_ready"]:
                return
            with connect() as conn:
                # two replicas can start at the same moment; the lock stops them racing
                conn.execute("SELECT pg_advisory_xact_lock(4242)")
                for statement in SCHEMA:
                    conn.execute(statement)
            state["schema_ready"] = True

    def run(fn):
        try:
            ensure_schema()
            with connect() as conn:
                return fn(conn)
        except psycopg.Error:
            state["schema_ready"] = False
            DB_ERRORS.inc()
            raise

    @app.errorhandler(psycopg.Error)
    def database_down(exc):
        log.error("database error", extra={"fields": {"error": str(exc)[:200]}})
        return jsonify(error="database unavailable"), 503

    @app.before_request
    def start_timer():
        g.t0 = time.perf_counter()

    @app.after_request
    def record(resp):
        duration = time.perf_counter() - g.get("t0", time.perf_counter())
        endpoint = request.url_rule.rule if request.url_rule else "unmatched"
        REQUESTS.labels(request.method, endpoint, str(resp.status_code)).inc()
        LATENCY.labels(endpoint).observe(duration)
        if request.path not in QUIET_PATHS:
            log.info(
                "request",
                extra={"fields": {
                    "method": request.method, "path": request.path,
                    "status": resp.status_code, "ms": round(duration * 1000, 1),
                }},
            )
        return resp

    @app.get("/")
    def index():
        hits = run(lambda c: c.execute(
            "INSERT INTO counters (name, n) VALUES ('hits', 1) "
            "ON CONFLICT (name) DO UPDATE SET n = counters.n + 1 RETURNING n"
        ).fetchone()[0])
        return jsonify(service="notes", version=cfg["VERSION"], instance=HOSTNAME, hits=hits)

    @app.get("/notes")
    def list_notes():
        rows = run(lambda c: c.execute(
            "SELECT id, text, created_at FROM notes ORDER BY id DESC LIMIT 20"
        ).fetchall())
        return jsonify([{"id": r[0], "text": r[1], "created_at": r[2].isoformat()} for r in rows])

    @app.post("/notes")
    def add_note():
        text = str((request.get_json(silent=True) or {}).get("text", "")).strip()
        if not text or len(text) > 200:
            return jsonify(error="text must be 1-200 characters"), 400
        note_id = run(lambda c: c.execute(
            "INSERT INTO notes (text) VALUES (%s) RETURNING id", (text,)
        ).fetchone()[0])
        return jsonify(id=note_id, text=text), 201

    @app.get("/healthz")
    def healthz():
        # Deliberately independent of the database: if Postgres blips we do not
        # want Docker restarting every healthy replica at once.
        if state["sick"]:
            return jsonify(status="sick", instance=HOSTNAME), 500
        return jsonify(status="ok", instance=HOSTNAME)

    @app.get("/readyz")
    def readyz():
        run(lambda c: c.execute("SELECT 1").fetchone())
        return jsonify(status="ready", instance=HOSTNAME)

    @app.get("/metrics")
    def metrics():
        return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

    if cfg["ENABLE_CHAOS"]:
        # Demo-only switches. nginx blocks /admin/ from outside, and the demo
        # scripts call them from inside the container.
        @app.post("/admin/crash")
        def crash():
            log.error("crash requested, killing the server process")
            under_gunicorn = request.environ.get("SERVER_SOFTWARE", "").startswith("gunicorn")

            def die():
                # Under gunicorn this code runs in a worker, and the master (PID 1
                # in the container) would simply respawn it, so the container would
                # never actually fail. Take the master down too, like an OOM kill.
                if under_gunicorn:
                    os.kill(os.getppid(), signal.SIGKILL)
                os._exit(1)

            threading.Timer(0.2, die).start()
            return jsonify(status="crashing"), 202

        @app.post("/admin/sicken")
        def sicken():
            state["sick"] = True
            log.warning("health endpoint now reports unhealthy")
            return jsonify(status="sick"), 200

        @app.post("/admin/heal")
        def heal():
            state["sick"] = False
            return jsonify(status="ok"), 200

    return app
