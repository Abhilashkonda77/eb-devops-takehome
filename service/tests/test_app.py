"""Unit tests for the demo service (run: cd service && pytest -q)."""
import socket
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import app as app_module  # noqa: E402


@pytest.fixture
def client(monkeypatch, tmp_path):
    # point CONFIG_DIR at an empty temp dir so the env-var path is exercised
    monkeypatch.setattr(app_module, "CONFIG_DIR", tmp_path)
    monkeypatch.setenv("APP_NAME", "from-env")
    monkeypatch.setenv("VERSION", "1.2.3")
    return app_module.app.test_client()


def test_root_reads_env(client):
    r = client.get("/")
    assert r.status_code == 200
    assert r.get_json() == {"app": "from-env", "version": "1.2.3", "pod": socket.gethostname()}


def test_healthz(client):
    assert client.get("/healthz").status_code == 200


def test_mounted_file_wins_over_env(client, tmp_path):
    (tmp_path / "APP_NAME").write_text("from-file\n")
    assert client.get("/").get_json()["app"] == "from-file"
    assert client.get("/").get_json()["version"] == "1.2.3"  # no file -> env


def test_file_change_is_picked_up_without_restart(client, tmp_path):
    (tmp_path / "VERSION").write_text("1.0.0")
    assert client.get("/").get_json()["version"] == "1.0.0"
    (tmp_path / "VERSION").write_text("2.0.0")
    assert client.get("/").get_json()["version"] == "2.0.0"


def test_empty_file_falls_back_to_env(client, tmp_path):
    (tmp_path / "APP_NAME").write_text("")
    assert client.get("/").get_json()["app"] == "from-env"


def test_defaults_when_nothing_set(monkeypatch, tmp_path):
    monkeypatch.setattr(app_module, "CONFIG_DIR", tmp_path)
    monkeypatch.delenv("APP_NAME", raising=False)
    monkeypatch.delenv("VERSION", raising=False)
    body = app_module.app.test_client().get("/").get_json()
    assert body["app"] == "demo" and body["version"] == "0.0.0"
