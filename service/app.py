"""Tiny demo HTTP service.

GET /         -> {"app": APP_NAME, "version": VERSION, "pod": hostname}
GET /healthz  -> 200 {"status": "ok"}

Config lookup order (per request, so changes are picked up without restart):
  1. file in CONFIG_DIR (default /etc/app-config) - a mounted ConfigMap,
     which the kubelet refreshes in place when the ConfigMap is patched
  2. environment variable of the same name
  3. built-in default
"""
import os
import socket
from pathlib import Path

from flask import Flask, jsonify

CONFIG_DIR = Path(os.environ.get("CONFIG_DIR", "/etc/app-config"))
DEFAULTS = {"APP_NAME": "demo", "VERSION": "0.0.0"}

app = Flask(__name__)


def get_setting(key: str) -> str:
    try:
        value = (CONFIG_DIR / key).read_text().strip()
        if value:
            return value
    except OSError:
        pass  # no mounted file -> fall back to env (e.g. plain `docker run -e`)
    return os.environ.get(key, DEFAULTS[key])


@app.get("/")
def index():
    return jsonify(
        app=get_setting("APP_NAME"),
        version=get_setting("VERSION"),
        pod=socket.gethostname(),
    )


@app.get("/healthz")
def healthz():
    return jsonify(status="ok"), 200


if __name__ == "__main__":  # local dev only; the container runs gunicorn
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
