# Backend (FastAPI)

Document Copilot API — retrieval, chat orchestration, and grounding.

**Requires:** Python 3.12+, [uv](https://docs.astral.sh/uv/), a Supabase project.

## Setup

```bash
cd backend
uv sync
```

Copy env vars into `backend/.env` (see [supabase-setup](../docs/guides/supabase-setup.md)). Required keys are read by `app/config.py`:

- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`
- `DATABASE_URL` (direct Postgres host for Alembic — not the pooler URL)
- `OPENAI_API_KEY`
- `ALLOWED_ORIGINS` (e.g. `http://localhost:5173`)

## Run

```bash
cd backend
uv run uvicorn app.main:app --reload
```

API: `http://localhost:8000` · Health: `GET /health`

Alternative:

```bash
uv run python app/main.py
```

## Dev

```bash
uv run pytest -m "not integration"   # unit tests
uv run ruff check app                  # lint
```

## Migrations

```bash
uv run alembic upgrade head
```

Full Alembic workflow: [backend-setup](../docs/guides/backend-setup.md).
