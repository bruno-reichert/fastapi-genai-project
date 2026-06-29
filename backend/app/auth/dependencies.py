"""FastAPI dependencies for Supabase JWT authentication."""

from __future__ import annotations

import uuid
from dataclasses import dataclass

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

# Import your existing factory
from app.database.supabase import create_user_client

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
    # Use your existing factory from app/database/supabase.py
    client = await create_user_client(access_token)

    try:
        # get_user validates the JWT
        response = await client.auth.get_user(access_token)
    except Exception:
        # General catch-all for network or library errors
        raise _unauthorized("Invalid or expired token")

    if response is None or response.user is None or not response.user.email:
        raise _unauthorized("Invalid or expired token")

    return CurrentUser(
        id=uuid.UUID(str(response.user.id)),
        email=response.user.email,
    )