"""Application settings — single source of truth for backend environment with defensive CORS parsing."""

from functools import lru_cache
from pathlib import Path
from typing import Annotated

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

_BACKEND_DIR = Path(__file__).resolve().parent.parent
_ENV_FILE = _BACKEND_DIR / ".env"


def _settings_config() -> SettingsConfigDict:
    kwargs: dict[str, object] = {
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }
    if _ENV_FILE.is_file():
        kwargs["env_file"] = _ENV_FILE
    return SettingsConfigDict(**kwargs)


class Settings(BaseSettings):
    model_config = _settings_config()

    # Supabase (Auth + API)
    supabase_url: str
    supabase_anon_key: str
    supabase_service_role_key: str

    # Postgres
    database_url: str

    # OpenAI / Groq
    openai_api_key: str
    openai_model_name: str = "llama-3.3-70b-versatile"
    openai_embedding_model: str = "sentence-transformers/all-MiniLM-L6-v2"
    openai_embedding_dimensions: int = 384

    # Server CORS
    allowed_origins: Annotated[list[str], NoDecode] = Field(
        default_factory=lambda: ["http://localhost:5173"]
    )

    @field_validator("allowed_origins", mode="before")
    @classmethod
    def parse_allowed_origins(cls, value: str | list[str]) -> list[str]:
        """Safely parse comma-separated origins and strip any accidental double or single quotes."""
        if isinstance(value, str):
            # Clean up commas, and strip any accidental quotes added by env parsers
            origins = [
                origin.strip().replace('"', '').replace("'", "")
                for origin in value.split(",")
                if origin.strip()
            ]
            return origins
        return value


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()