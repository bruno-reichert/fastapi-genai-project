FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

# Install high-speed uv package manager natively
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Copy dependency specifications first to leverage Docker layer caching
COPY pyproject.toml uv.lock ./

# Pass --no-cache to prevent saving duplicate installer zips on disk
RUN uv sync --frozen --no-dev --no-install-project --no-cache

# Copy application layers
COPY alembic ./alembic
COPY alembic.ini ./
COPY app ./app
COPY ingest ./ingest
COPY scripts ./scripts

# Perform final sync of your codebase packages with zero caching
RUN uv sync --frozen --no-dev --no-cache

ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8000

# Start Uvicorn, mapping the listening port directly to the dynamic $PORT assigned by Railway
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]