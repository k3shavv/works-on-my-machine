"""Unit tests. A tiny in-memory fake stands in for Postgres, so these run
anywhere. The real database is exercised by the compose smoke test in CI."""
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from main import create_app


class FakeCursor:
    def __init__(self, rows):
        self.rows = rows

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


class FakeDB:
    def __init__(self):
        self.hits = 0
        self.notes = []
        self.down = False

    def connect(self):
        return FakeConn(self)


class FakeConn:
    def __init__(self, db):
        self.db = db

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, params=None):
        if self.db.down:
            raise psycopg.OperationalError("connection refused")
        s = " ".join(sql.split()).lower()
        if s.startswith("insert into counters"):
            self.db.hits += 1
            return FakeCursor([(self.db.hits,)])
        if s.startswith("insert into notes"):
            self.db.notes.append((len(self.db.notes) + 1, params[0]))
            return FakeCursor([(len(self.db.notes),)])
        if s.startswith("select id, text"):
            now = datetime.now(timezone.utc)
            return FakeCursor([(i, t, now) for i, t in reversed(self.db.notes)])
        if s.startswith("select 1"):
            return FakeCursor([(1,)])
        return FakeCursor([])  # schema statements and advisory lock


@pytest.fixture
def db():
    return FakeDB()


@pytest.fixture
def client(db):
    return create_app({"CONNECT": db.connect, "VERSION": "test"}).test_client()


def test_missing_database_url_fails_with_helpful_message(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    with pytest.raises(RuntimeError, match=".env.example"):
        create_app()


def test_healthz_does_not_need_the_database(client, db):
    db.down = True
    assert client.get("/healthz").status_code == 200


def test_readyz_ok_then_503_when_database_is_down(client, db):
    assert client.get("/readyz").status_code == 200
    db.down = True
    assert client.get("/readyz").status_code == 503


def test_hit_counter_and_version(client):
    first = client.get("/").get_json()
    second = client.get("/").get_json()
    assert second["hits"] == first["hits"] + 1
    assert first["version"] == "test" and first["instance"]


def test_add_and_list_notes(client):
    assert client.post("/notes", json={"text": "hello"}).status_code == 201
    notes = client.get("/notes").get_json()
    assert notes[0]["text"] == "hello"


@pytest.mark.parametrize("payload", [{}, {"text": ""}, {"text": "x" * 201}])
def test_note_validation(client, payload):
    assert client.post("/notes", json=payload).status_code == 400


def test_database_outage_returns_503_not_a_stack_trace(client, db):
    db.down = True
    r = client.get("/notes")
    assert r.status_code == 503 and r.get_json() == {"error": "database unavailable"}


def test_app_recovers_when_database_returns(client, db):
    db.down = True
    assert client.get("/notes").status_code == 503
    db.down = False
    assert client.get("/notes").status_code == 200


def test_metrics_endpoint_exposes_counters(client):
    client.get("/")
    body = client.get("/metrics").get_data(as_text=True)
    assert "http_requests_total" in body and "http_request_duration_seconds" in body


def test_chaos_endpoints_are_off_by_default(client):
    assert client.post("/admin/crash").status_code == 404
    assert client.post("/admin/sicken").status_code == 404


def test_sicken_and_heal_toggle_healthz(db):
    app = create_app({"CONNECT": db.connect, "ENABLE_CHAOS": True})
    c = app.test_client()
    assert c.post("/admin/sicken").status_code == 200
    assert c.get("/healthz").status_code == 500
    assert c.post("/admin/heal").status_code == 200
    assert c.get("/healthz").status_code == 200
    assert "/admin/crash" in {r.rule for r in app.url_map.iter_rules()}
