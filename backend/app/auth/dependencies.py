"""FastAPI dependencies for Supabase JWT authentication with diagnostic logging."""

from __future__ import annotations

import uuid
from dataclasses import dataclass

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from supabase import acreate_client
from supabase.lib.client_options import AsyncClientOptions
from supabase_auth.errors import AuthApiError

from app.config import settings

_bearer = HTTPBearer(auto_error=False)


@dataclass(frozen=True, slots=True)
class CurrentUser:
    id: uuid.UUID
    email: str


def _unauthorized(detail: str = "Not authenticated") -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


async def get_access_token(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> str:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise _unauthorized()

    token = credentials.credentials.strip()
    if not token:
        raise _unauthorized()

    return token


async def get_current_user(
    access_token: str = Depends(get_access_token),
) -> CurrentUser:
    print("[AUTH] Resolving get_current_user dependency...", flush=True)
    
    # Initialize requesting client
    headers = {"Authorization": f"Bearer {access_token}"}
    options = AsyncClientOptions(
        headers=headers,
        auto_refresh_token=False,
        persist_session=False,
    )
    
    print("[AUTH] Connecting to Supabase Auth to fetch active profile...", flush=True)
    try:
        client = await acreate_client(
            settings.supabase_url,
            settings.supabase_anon_key,
            options=options,
        )
        response = await client.auth.get_user(access_token)
        print("[AUTH] User response successfully retrieved from Supabase Auth!", flush=True)
    except Exception as exc:
        print(f"[AUTH] Error during get_user auth request: {exc}", flush=True)
        raise _unauthorized("Invalid or expired token")

    if response is None or response.user is None or not response.user.email:
        print("[AUTH] User profile is empty or malformed!", flush=True)
        raise _unauthorized("Invalid or expired token")

    user_id = uuid.UUID(str(response.user.id))
    print(f"[AUTH] User successfully validated: {response.user.email} (id: {user_id})", flush=True)
    return CurrentUser(
        id=user_id,
        email=response.user.email,
    )