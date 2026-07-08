"""FastAPI application entrypoint with structured logging and global error handling."""

from __future__ import annotations

import logging
import sys
import structlog
from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.auth import router as auth_router
from app.api.chat import router as chat_router
from app.config import settings

# Initialize standard Python logging to match structlog
logging.basicConfig(
    format="%(message)s",
    stream=sys.stdout,
    level=logging.INFO,
)

# Configure structlog to output clean, structured JSON in terminal
structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
    context_class=dict,
    logger_factory=structlog.PrintLoggerFactory(),
    cache_logger_on_first_use=True,
)

logger = structlog.get_logger()

app = FastAPI(title="Document Copilot")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request, exc: RequestValidationError):
    """Intercept validation anomalies and log metrics inside a structured JSON schema."""
    raw_body = None
    try:
        body_bytes = await request.body()
        raw_body = body_bytes.decode("utf-8")
    except Exception:
        raw_body = "<failed to decode body>"

    logger.error(
        "request_validation_failed",
        url=str(request.url),
        method=request.method,
        errors=exc.errors(),
        body=raw_body,
    )
    
    # Sanitize bytes inside error dicts to ensure JSON serializable
    sanitized_errors = []
    for error in exc.errors():
        sanitized_error = dict(error)
        if "input" in sanitized_error and isinstance(sanitized_error["input"], bytes):
            try:
                sanitized_error["input"] = sanitized_error["input"].decode("utf-8")
            except Exception:
                sanitized_error["input"] = str(sanitized_error["input"])
        sanitized_errors.append(sanitized_error)
    
    return JSONResponse(
        status_code=422,
        content={"detail": sanitized_errors},
    )


app.include_router(auth_router)
app.include_router(chat_router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)
