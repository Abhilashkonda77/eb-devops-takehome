# syntax=docker/dockerfile:1

# ---- build stage: install deps into an isolated venv ----
FROM python:3.12.7-slim-bookworm AS builder
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install -r requirements.txt

# ---- runtime stage: venv + app only, no pip cache or build leftovers ----
FROM python:3.12.7-slim-bookworm
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_NAME=demo \
    VERSION=0.0.0
# numeric UID so Kubernetes runAsNonRoot can verify it
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=10001:10001 app.py .
USER 10001
EXPOSE 8080
# heartbeat files go to /tmp (an emptyDir in k8s) so the root FS can be read-only
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--worker-tmp-dir", "/tmp", "--access-logfile", "-", "app:app"]
