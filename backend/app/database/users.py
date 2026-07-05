"""User record provisioning for Supabase Auth users using direct SQL."""

from __future__ import annotations

import asyncio
from sqlalchemy.dialects.postgresql import insert

from app.auth.dependencies import CurrentUser
from app.database.session import get_session
from app.database.models.user import User


async def ensure_user(user: CurrentUser) -> None:
    """Upsert the authenticated user into the users table via direct, high-performance SQL."""
    def _sync_upsert() -> None:
        with get_session() as session:
            # Build a direct upsert statement (INSERT ON CONFLICT DO UPDATE)
            stmt = insert(User).values(id=user.id, email=user.email)
            stmt = stmt.on_conflict_do_update(
                index_elements=["id"],
                set_={"email": user.email}
            )
            session.execute(stmt)
            session.commit()

    # Safely dispatch the synchronous DB transaction to a background worker thread
    await asyncio.to_thread(_sync_upsert)