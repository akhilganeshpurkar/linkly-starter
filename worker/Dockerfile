# ==========================================
# Stage 1: Builder
# ==========================================
FROM python:3.12-slim-bookworm AS builder

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /build

# Create virtual environment
RUN python -m venv $VIRTUAL_ENV

# Copy requirements
COPY requirements.txt .

# Install dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt


# ==========================================
# Stage 2: Runtime
# ==========================================
FROM python:3.12-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    REPORT_DIR=/reports \
    HEARTBEAT_FILE=/tmp/worker-heartbeat

WORKDIR /app

# Create non-root user and reports directory
RUN groupadd --gid 10001 app && \
    useradd --uid 10001 \
            --gid 10001 \
            --create-home \
            --home-dir /home/app \
            --shell /usr/sbin/nologin app && \
    mkdir -p /reports && \
    chown -R 10001:10001 /reports

# Copy dependencies from builder
COPY --from=builder /opt/venv /opt/venv

# Copy worker application
COPY --chown=10001:10001 worker.py healthcheck.py ./

# Run as non-root user
USER 10001:10001

# Health check
HEALTHCHECK --interval=10s \
            --timeout=4s \
            --start-period=20s \
            --retries=3 \
    CMD ["python", "/app/healthcheck.py"]

# Start worker
CMD ["python", "/app/worker.py"]
