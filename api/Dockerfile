# ==========================================
# Stage 1: Builder
# ==========================================
FROM python:3.12-slim-bookworm AS builder

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /build

# Create virtual environment
RUN python -m venv $VIRTUAL_ENV

# Copy requirements separately for better caching
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
    PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# Create non-root user
RUN groupadd --gid 10001 app && \
    useradd --uid 10001 \
            --gid 10001 \
            --create-home \
            --home-dir /home/app \
            --shell /usr/sbin/nologin app

# Copy installed dependencies from builder
COPY --from=builder /opt/venv /opt/venv

# Copy application files
COPY --chown=10001:10001 app.py healthcheck.py ./

# Run as non-root user
USER 10001:10001

EXPOSE 5000

# Health check
HEALTHCHECK --interval=10s \
            --timeout=4s \
            --start-period=25s \
            --retries=3 \
    CMD ["python", "/app/healthcheck.py"]

# Start API using Gunicorn
CMD ["gunicorn", \
     "--bind", "0.0.0.0:5000", \
     "--workers", "2", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
