"""FastAPI application entrypoint with global request validation debugger."""

from __future__ import annotations

import traceback
from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.auth import router as auth_router
from app.api.chat import router as chat_router
from app.config import settings

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
    """Intercept 422 errors and print exact Pydantic validation errors and raw payloads."""
    print("\n" + "="*50)
    print("[SERVER] RequestValidationError Intercepted!", flush=True)
    print(f"[SERVER] Request URL: {request.method} {request.url}", flush=True)
    print(f"[SERVER] Validation Errors: {exc.errors()}", flush=True)
    try:
        body = await request.body()
        print(f"[SERVER] Raw Request Body payload: {body.decode()}", flush=True)
    except Exception as body_exc:
        print(f"[SERVER] Could not read raw body: {body_exc}", flush=True)
    print("="*50 + "\n")
    
    # Sanitize bytes inside error dicts to ensure they are JSON serializable
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