# Document Copilot — implementation checklist

Track progress toward the full architecture and client brief ([client-brief.md](client-brief.md)). See [architecture.md](architecture.md) for design details and the setup guides under [guides/](guides/) for commands.

**Order:** Supabase foundation → scaffold both services → backend leads (schema, auth, retrieval, LLM) → frontend in vertical slices → deploy → pilot.

---

## Phase 0 — Accounts & credentials

- [X] Supabase project created (free tier is fine for dev)
- [ ] Email auth enabled; disable "confirm email" for local dev if needed
- [ ] OpenAI API key with billing set up
- [ ] `backend/.env` and `frontend/.env` filled in (never commit these)
- [X] Sample SEC filings downloaded via `uv run data/download.py`

---

## Phase 1 — Project scaffolding

- [ ] Backend deps installed per [guides/backend-setup.md](guides/backend-setup.md)
- [ ] Backend: `app/main.py` with health check (`GET /health`)
- [ ] Backend: `app/config.py` — single settings module, fail fast on missing vars
- [ ] Backend: CORS configured for `http://localhost:5173`
- [ ] Frontend: Vite + React + TypeScript + Tailwind + shadcn initialized per [guides/frontend-setup.md](guides/frontend-setup.md)
- [ ] Frontend: `src/lib/env.ts` validates `VITE_API_BASE_URL`, `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`
- [ ] Both services run locally without errors

---

## Phase 2 — Database schema (backend-led)

- [ ] Alembic initialized; `env.py` reads `DATABASE_URL` from settings
- [ ] SQLAlchemy models in `app/database/models.py`:
  - [ ] `profiles`
  - [ ] `chat_threads`, `chat_messages`, `message_citations`
  - [ ] `source_documents`, `document_chunks` (embedding + `tsvector`)
- [ ] Initial migration reviewed and applied:
  - [ ] `create extension vector`
  - [ ] HNSW index on embeddings
  - [ ] GIN index on full-text vectors
  - [ ] RLS policies on user-owned tables
- [ ] `uv run alembic upgrade head` succeeds against Supabase

---

## Phase 3 — Authentication

- [ ] Frontend: `src/lib/supabase.ts` + sign-in / sign-up pages (email only)
- [ ] Frontend: protected routes — redirect unauthenticated users
- [ ] Backend: `app/auth/dependencies.py` — verify `Authorization: Bearer <token>` via Supabase
- [ ] Backend: `get_current_user` dependency on all protected routes
- [ ] End-to-end: sign in in browser → backend accepts token → rejects invalid/expired tokens with `401`

---

## Phase 4 — API layer & chat skeleton

- [ ] Frontend: `src/lib/http.ts` + `src/lib/api.ts` (base URL, bearer token, typed errors)
- [ ] Backend: thread CRUD — list threads, create thread, load message history (user-scoped)
- [ ] Backend: `POST /chat/stream` — stub response streaming AI SDK-compatible events
- [ ] Frontend: chat page with Vercel AI SDK `useChat` pointed at FastAPI
- [ ] End-to-end: authenticated user sends message → sees streamed stub reply → thread persists

---

## Phase 5 — Ingestion pipeline

- [ ] Parse downloaded SEC filings → normalized Markdown in `source_documents`
- [ ] Chunk text with metadata (company, ticker, filing type, date, section, page)
- [ ] Generate embeddings via OpenAI (`text-embedding-3-small`, 1536 dims)
- [ ] Generate Postgres `tsvector` for full-text search
- [ ] Write chunks + embeddings to Supabase
- [ ] Verify corpus: all 5 companies × 2021–2025 10-Ks ingested and searchable
- [ ] Unit tests for chunking and metadata extraction

---

## Phase 6 — Retrieval (hybrid search)

- [ ] Semantic search over `document_chunks.embedding` via `pgvector`
- [ ] Lexical search over `document_chunks.search_vector` via Postgres FTS
- [ ] Reciprocal Rank Fusion in Python to merge ranked lists
- [ ] Fetch neighboring chunks for grounding context
- [ ] Unit tests for fusion logic and query helpers

---

## Phase 7 — LLM orchestration (PydanticAI)

- [ ] `assistant/agent.py` — typed agent with explicit deps
- [ ] `assistant/instructions.md` — product contract (cite claims, refuse when insufficient, no stock picks)
- [ ] Bounded tools: `search_filings`, `read_chunk`, `read_surrounding_chunks`
- [ ] `GroundedAnswer` output type with citations and source passages
- [ ] `chat/orchestrator.py` — full turn lifecycle (retrieve → generate → validate → persist)

---

## Phase 8 — Grounding & trust enforcement

- [ ] `grounding/validator.py` — every citation maps to a retrieved passage
- [ ] Fail closed on validation errors (no polished hallucinated answer)
- [ ] Persist user message, assistant message, and citation records after successful run
- [ ] Unit tests for citation extraction and grounding invariants

---

## Phase 9 — Frontend polish (trust UX)

- [ ] Citation badges on assistant messages (filing + page/section)
- [ ] Expandable source passages for one-click verification
- [ ] Thread sidebar with past conversations
- [ ] Empty states, streaming indicator, error states (401, network, grounding failure)
- [ ] Manual smoke test against the 10 example analyst questions in [client-brief.md](client-brief.md)

---

## Phase 10 — Deployment

- [ ] Railway: backend service (Uvicorn)
- [ ] Railway: frontend service (Vite static build)
- [ ] Production env vars set on both services
- [ ] Supabase auth settings tightened for production (email confirmation, etc.)
- [ ] CORS `ALLOWED_ORIGINS` updated to production frontend URL

---

## Phase 11 — Pilot readiness (definition of done)

Success = 5 senior analysts use it for a week and each saves ≥3 hours per week.

- [ ] Pilot accounts created for the analyst group
- [ ] All 10 sample questions from the brief return cited answers or honest "not enough evidence" refusals
- [ ] Wrong-but-confident answers blocked by grounding enforcement (not prompt-only)
- [ ] Response latency acceptable for interactive chat (<30s for complex multi-filing questions)
- [ ] Brief walkthrough doc or 15-min demo for the pilot group
