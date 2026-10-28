"""FastAPI application entry point. Run with: uvicorn app.main:app"""

from fastapi import FastAPI

from app.api import health
from app.core.settings import get_settings

settings = get_settings()

app = FastAPI(title=settings.app_name)
app.include_router(health.router)
