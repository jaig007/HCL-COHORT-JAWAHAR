# ---------- Stage 1: builder (installs Python packages) ----------
# Slim official Python 3.12 image; named "builder" so stage 2 can copy from it
FROM python:3.12-slim AS builder

# Create a virtual environment so all packages live in one folder we can copy later
RUN python -m venv /opt/venv
# Put the venv first on PATH so "pip" and "python" below use it
ENV PATH="/opt/venv/bin:$PATH"

# Copy only the requirements first, so this layer is cached until requirements change
COPY requirements.txt .
# Install packages; --no-cache-dir keeps pip's download cache out of the image
RUN pip install --no-cache-dir -r requirements.txt


# ---------- Stage 2: runtime (what actually ships) ----------
# Start again from a clean slim image; nothing from stage 1 comes along unless copied
FROM python:3.12-slim AS runtime

# Don't write .pyc files, and print logs immediately instead of buffering them
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    UVICORN_WORKERS=1

# Create an unprivileged user and group called "app" (no login shell, no password)
RUN groupadd --system app && useradd --system --gid app --no-create-home app

# All following commands and the running app use this folder
WORKDIR /srv

# Copy the ready-made venv from the builder stage
COPY --from=builder /opt/venv /opt/venv
# Copy our application code, owned by the app user
COPY --chown=app:app app/ ./app/

# From here on, run as the non-root user
USER app

# Document that the server listens on port 8000 (the mapping is done in compose)
EXPOSE 8000

# Every 30s, call /health with Python (slim has no curl); non-200 or error = unhealthy
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)" || exit 1

# sh -c lets $UVICORN_WORKERS be expanded; exec makes uvicorn PID 1 so it gets stop signals
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers ${UVICORN_WORKERS}"]
