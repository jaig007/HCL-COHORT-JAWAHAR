"""Health and readiness endpoints."""

from fastapi import APIRouter

router = APIRouter(tags=["health"])


@router.get("/health")
def health() -> dict[str, str]:
    """Liveness check: 200 whenever the process is up."""
    return {"status": "ok"}


@router.get("/ready")
def ready() -> dict[str, str]:
    """Readiness check: can the gateway serve requests?"""
    # TODO: in later labs, check that config and prompts loaded and at least
    # one provider has credentials; return 503 with reasons if not.
    return {"status": "ready"}
