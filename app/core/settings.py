"""Gateway settings, loaded from environment variables and the .env file."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """All gateway configuration in one typed object.

    Each field maps to an env var with the same name in upper case
    (app_name -> APP_NAME). Real env vars override values from .env.
    """

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "LLM Gateway"
    log_level: str = "INFO"
    # Not used yet; the config loader arrives in a later lab.
    models_config_path: str = "config/models.yaml"


@lru_cache
def get_settings() -> Settings:
    """Return one shared Settings instance (read .env only once)."""
    return Settings()
