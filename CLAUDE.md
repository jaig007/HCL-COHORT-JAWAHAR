# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Source of truth

Requirements live in `docs/specs/llm-gateway-v1.md`. Read it before planning any feature. Do not copy it here. When a requirement changes, update the spec in the same change. Later spec versions go in new files (`v2`, `v3`, ...).

The project is built in stages, and each stage needs user approval before the next starts (see the spec's "Build stages"). Before writing code for a stage, propose a short plan and wait for approval. After each stage, run the tests and fix any failures.

## What this is

An LLM Gateway: one OpenAI-compatible HTTP service (FastAPI, Python 3.12) that AI agents call instead of calling providers directly. It routes each request to a model tier based on a complexity score, retries and falls back across providers (OpenAI, Anthropic, Gemini, Ollama), traces to Langfuse, and tracks cost savings against a baseline model.

Current state: early stage 1 scaffolding. The repo has only the FastAPI app, settings, the `/health` and `/ready` endpoints, and a Dockerfile plus docker-compose.yml. `/ready` is a stub with a TODO.

## Commands

```bash
python -m venv .venv
.venv\Scripts\activate            # Windows; use source .venv/bin/activate on POSIX
pip install -r requirements.txt
copy .env.example .env             # then edit values

uvicorn app.main:app --reload      # dev server; API docs at http://localhost:8000/docs
docker compose up --build          # run in Docker (needs .env); workers from UVICORN_WORKERS
```

Planned in the spec but not set up yet: `pytest` (with pytest-asyncio and respx) and `ruff check`. When they arrive, run one test with `pytest tests/unit/test_x.py::test_name`.

## Architecture

- `app/main.py`: builds the `FastAPI` app and includes the routers from `app/api/`. The spec says the lifespan (loading config and prompts, flushing Langfuse) and middleware will live here.
- `app/core/settings.py`: one typed `Settings` (pydantic-settings) read from env vars and `.env`, with real env vars taking priority. Always get it through the cached `get_settings()`. Add new env vars as fields here and document them in `.env.example`.
- `app/api/`: one `APIRouter` per area (health, and later chat, models, stats).

Planned layout from the spec: `providers/` (a `BaseProvider` adapter for each provider), `routing/` (complexity scorer, router, retry, circuit breaker), `prompts/` (`PromptLoader`), `observability/`, `cost/`, `schemas/`, plus `config/models.yaml`, the top-level `prompts/` folder, and `tests/{unit,integration,fixtures}`.

## Rules that apply across stages

- No prompt text in Python. Runtime prompts live in `prompts/<name>/v<N>.yaml` and are rendered with Jinja2 `StrictUndefined`.
- Model IDs, tiers, pricing, retry and circuit-breaker settings go in `config/models.yaml`, never in code. Invalid config must fail startup.
- Never invent model prices. Use placeholders marked `# TODO: verify`.
- Use `Decimal` for money. Round only for display (6 decimal places).
- Langfuse failures must never break a request.
- API keys never appear in responses, logs or Langfuse. Prompt content is not logged to stdout by default.
- Errors use the OpenAI error shape (`{"error": {...}}`).
- Tests must never call a real provider or a real Langfuse server. Mock HTTP with respx.
- Ask before adding any dependency the spec does not list. If the spec is unclear, ask.
- Keep functions small and type-hinted. Add docstrings to public classes. Write an ADR in `docs/adr/` for each significant decision.
