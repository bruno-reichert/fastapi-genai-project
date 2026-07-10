# Document Copilot

An internal AI-powered RAG research assistant that lets investment analysts query a corpus of SEC financial filings in plain English and retrieve verified, fully grounded answers with interactive, clickable citation links.

---

## Technical Stack

| Layer | Choice | Role |
| --- | --- | --- |
| **Backend** | Python 3.12+ (FastAPI) | HTTP API Router & Orchestration |
| **LLM Engine** | Llama 3.3 70B (Groq Cloud) | Generation, Synthesis, and Citation Drafting |
| **Embeddings** | all-MiniLM-L6-v2 (Local) | Local 384-dimensional vector calculations |
| **Frontend** | React SPA (Vite + TypeScript) | Responsive, dual-pane citable user dashboard |
| **Database** | Supabase (PostgreSQL + pgvector) | Chunks, vector storage, users, and thread persistence |
| **Migrations** | Alembic + SQLAlchemy | Direct administrative schema modifications |
| **Auth** | Supabase Auth (Email/Password) | Secure session-token exchanges |
| **Package Managers** | `uv` (Python) / `pnpm` (Node) | High-speed, lockfile-safe environment syncs |

---

## Directory Layout

```text
document-copilot/
├── data/               # Raw HTML downloads, generated Markdown, & manifests
├── docs/               # System architecture design notes and checklists
├── backend/            # FastAPI API server (retrieval, agents, grounding)
└── frontend/           # React Single Page Application (Vite)
```

---

## Prerequisites

Before running locally, ensure you have the following environments installed on your machine:
*   **Python**: 3.12 or 3.13
*   **uv**: High-performance Python package manager (`curl -LsSf https://astral.sh/uv/install.sh | sh`)
*   **Node.js**: 20+ (LTS)
*   **pnpm**: High-speed Node package manager (`corepack enable && corepack prepare pnpm@latest --activate`)
*   **Supabase Project**: An active, hosted Supabase database instance with Email Auth enabled.
*   **Groq Cloud Account**: An active Groq API token (`gsk_...`) to run Llama 3.3.

---

## Local Setup

### 1. Database Migrations

Locate your direct database connection string inside your Supabase settings dashboard (**Project Settings** -> **Database** -> **Connection string** -> Choose **Transaction (Direct/Session)** and port `5432`).

Create your `backend/.env` file:
```bash
cd backend
cp .env.example .env
```

Configure your environment variables:
```env
SUPABASE_URL="https://your-project-ref.supabase.co"
SUPABASE_ANON_KEY="your-anon-public-key"
SUPABASE_SERVICE_ROLE_KEY="your-secret-service-role-key"

# MUST use the direct database connection (port 5432), not the transaction pooler
DATABASE_URL="postgresql+psycopg://postgres.your-ref:password@aws-0-us-east-1.pooler.supabase.com:5432/postgres"

# Model selection configurations (Groq)
OPENAI_API_KEY="your-groq-key-gsk_..."
GROQ_API_KEY="your-groq-key-gsk_..."
OPENAI_MODEL_NAME="llama-3.3-70b-versatile"

# Local embeddings model (384-dims)
OPENAI_EMBEDDING_MODEL="sentence-transformers/all-MiniLM-L6-v2"
OPENAI_EMBEDDING_DIMENSIONS=384

# CORS settings
ALLOWED_ORIGINS="http://localhost:5173"
```

Sync dependencies and apply your migrations cleanly:
```bash
# Sync dependencies in virtual environment
uv sync

# Run database schema upgrade head
uv run alembic upgrade head
```

---

### 2. Ingestion Pipeline (Populating your Corpus)

Follow these steps to download, convert, load, chunk, and embed SEC filings from scratch:

```bash
# Step A: Download 10-K filings from SEC EDGAR (stores HTML in data/downloads/)
# (Be sure to edit the USER_AGENT details at the top of download.py to avoid throttling)
uv run data/download.py

# Step B: Convert HTML layouts to Markdown (stores Markdown in data/markdown/)
uv run data/convert_to_markdown.py

# Step C: Provision your Supabase database user profiles table
uv run python -m ingest.load_source_documents

# Step D: Execute layout-aware chunking and generate local semantic vector embeddings
# This downloads all-MiniLM-L6-v2 on its first pass and caches it locally
uv run python -m ingest.chunk_and_embed --all --force
```

---

### 3. Frontend Configurations

Create your `frontend/.env` file:
```bash
cd ../frontend
cp .env.example .env
```

Ensure your configuration aligns with standard local routing:
```env
VITE_API_BASE_URL="http://localhost:8000"
VITE_SUPABASE_URL="https://your-project-ref.supabase.co"
VITE_SUPABASE_ANON_KEY="your-anon-public-key"
```

Sync all packages:
```bash
pnpm install
```

---

## Running the Application Locally

Start both servers concurrently using separate terminal tabs:

### Tab 1: Start Backend API
```bash
cd backend
uv run uvicorn app.main:app --reload
```
API Root: [http://localhost:8000](http://localhost:8000) · Swagger Docs: [http://localhost:8000/docs](http://localhost:8000/docs)

### Tab 2: Start Frontend client
```bash
cd frontend
pnpm dev
```
Client: [http://localhost:5173](http://localhost:5173)

Sign up with an email and password, click **"New Chat"**, and enter your query!

---

## Local Pipeline Verification (Smoke Testing)

To test specific layers of your application in isolation, run these standalone backend test scripts:

*   **Hybrid Search Testing**: Validate that hybrid pgvector and keyword FTS return correct files and scores:
    ```bash
    uv run python scripts/smoke_retrieval.py
    ```
*   **LLM & Grounding Testing**: Validate that your PydanticAI model, prompt context, and citation auto-healer function cleanly:
    ```bash
    uv run python scripts/smoke_assistant.py
    ```
```

REDEPLOY BUTTON <-
WHAT DO YOU **MEAN** INFRASTRUCTURE ERROR