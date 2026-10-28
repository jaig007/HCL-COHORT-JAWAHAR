# Spec: LLM Gateway server for AI agents (v1)

> Save this file in the repo as `docs/specs/llm-gateway-v1.md`.
> In Claude Code, start with: "Read docs/specs/llm-gateway-v1.md and propose a plan."

## Task

You are a senior Python backend engineer. Build a production-quality **LLM Gateway**: a single
HTTP service that AI agents call instead of calling LLM providers directly. The gateway picks
the right model, calls the provider, retries or falls back on failure, logs everything to
Langfuse, and reports how much money routing saved.

Work in stages. **Before writing code, propose a short plan and the folder structure, then wait
for my approval.** After each stage, run the tests and fix failures before moving on.

Build stages (approve each before the next):
1. Repo scaffolding, settings, config loader, prompt loader, health endpoints, Docker
2. Provider adapters + unified schemas + `/v1/chat/completions` (non-streaming)
3. Routing: complexity scorer, tiers, retries, fallback, circuit breaker
4. Langfuse observability + structured logging
5. Cost tracking + `/v1/stats/costs`
6. Streaming, README, final acceptance check

---

## Tech stack
- Python 3.12, FastAPI, Uvicorn, Pydantic v2, pydantic-settings
- `httpx` (async) and the official provider SDKs where useful
- Langfuse Python SDK (current major version, check its docs for the up-to-date API)
- Jinja2 (prompt templates), PyYAML
- pytest + pytest-asyncio, respx (to mock HTTP)
- Docker + docker-compose
- Ruff for linting, type hints throughout

---

## Repository conventions (specs, prompts and Claude Code files)

The repo must separate **specs** (what to build), **runtime prompts** (text sent to LLMs by the
gateway), and **code**. Create this layout:

```
llm-gateway/
├── CLAUDE.md                     # short, permanent rules for Claude Code (see below)
├── docs/
│   ├── specs/
│   │   └── llm-gateway-v1.md     # this file; later versions get new files (v2, v3...)
│   ├── adr/                      # architecture decision records, one file per decision
│   │   └── 0001-openai-compatible-api.md
│   └── architecture.md           # request flow diagram (Mermaid) and component overview
├── .claude/
│   └── commands/
│       ├── add-provider.md       # reusable prompt: add a new provider adapter + tests
│       ├── add-model.md          # reusable prompt: add a model to config + pricing
│       └── review.md             # reusable prompt: review a diff against this spec
├── prompts/                      # runtime prompts, versioned, never inline in Python
│   ├── README.md
│   └── complexity_classifier/
│       └── v1.yaml
├── app/ ...
├── config/
│   └── models.yaml
└── tests/ ...
```

### CLAUDE.md
Keep it under ~100 lines. Include only lasting facts: how to run, test, lint, and build; the
folder layout; coding rules; and "the source of truth for requirements is
`docs/specs/llm-gateway-v1.md`". Do not copy this whole spec into it.

### ADRs
Write a short ADR (Context / Decision / Consequences) for each significant choice, at minimum:
OpenAI-compatible API, heuristic complexity scoring, in-memory vs Redis cost totals, prompt
storage approach.

### Runtime prompt management
- No prompt text is hard-coded in Python. All prompts live in `prompts/<name>/v<N>.yaml`.
- Prompt file format:
  ```yaml
  name: complexity_classifier
  version: 1
  description: Classifies a request as simple, medium or complex
  model: <cheap-model-id>         # model used to run this prompt
  temperature: 0
  max_tokens: 5
  variables: [prompt]
  system: |
    Classify the user's request as simple, medium or complex.
    Reply with exactly one word.
  user_template: |
    Request:
    {{ prompt }}
  ```
- `app/prompts/loader.py` provides a `PromptLoader`:
  - `get(name, version="latest" | int) -> Prompt`
  - renders templates with Jinja2 using `StrictUndefined` (missing variable = error)
  - validates files with a Pydantic model at startup; invalid prompt files fail startup
  - caches loaded prompts in memory
- Optional **Langfuse Prompt Management** source, enabled with `PROMPT_SOURCE=langfuse`:
  fetch by name and label (`production` by default), cache with a TTL, and fall back to the
  local YAML file if Langfuse is unreachable. Default is `PROMPT_SOURCE=local`.
- Every generation that uses a prompt records `prompt_name` and `prompt_version` in Langfuse.
- The LLM-based complexity classifier (Feature 3) is the first consumer of this system.
  It is off by default (`COMPLEXITY_SCORER=heuristic`).

---

## Feature 1: Multi-LLM support (one interface, many providers)
- Define a `BaseProvider` abstract class with async `chat()` and `stream_chat()` methods that
  take and return the gateway's own unified request/response models.
- Implement providers for: **OpenAI, Anthropic, Google Gemini, and Ollama (local)**.
  Each adapter translates the unified format to and from the provider's format
  (messages, system prompt, temperature, max_tokens, tool calls if supported).
- Normalize the response: text, model used, provider, input tokens, output tokens,
  finish reason, latency in ms.
- Normalize errors into gateway error types: `RateLimitError`, `TimeoutError`,
  `AuthError`, `ProviderUnavailableError`, `BadRequestError`.
- Expose an **OpenAI-compatible endpoint** so existing agent frameworks work unchanged:
  - `POST /v1/chat/completions` (supports `stream: true` via Server-Sent Events)
  - `GET /v1/models` (lists configured models)
- `model` in the request can be a real model name (bypass routing) or `"auto"` (use routing).
- New providers must be addable by writing one adapter class and one config entry.

## Feature 2: Observability with Langfuse
- Every request creates a Langfuse **trace**. Each provider attempt (including retries and
  fallbacks) is a **generation** inside it, recording: model, provider, input, output,
  input/output tokens, cost, latency, status, and error message on failure.
- Attach metadata: routing decision, complexity score, routing reason, attempt number,
  whether a fallback was used, estimated savings, and prompt name/version when a gateway
  prompt was used.
- Accept optional headers from agents and pass them to Langfuse:
  `X-Agent-Id`, `X-Session-Id`, `X-User-Id`, plus a request ID (generate one if missing
  and return it in the `X-Request-Id` response header).
- Langfuse must never break a request. If it is down or not configured, log a warning and
  continue. Flush events on shutdown.
- Also emit structured JSON logs for each request.

## Feature 3: Model routing, retries and fallback
- **Complexity scorer**: score each prompt from 0 to 1 using cheap heuristics, such as
  token count, number of messages, presence of code blocks, reasoning keywords
  ("analyze", "step by step", "prove", "compare"), tool definitions, and requested
  output length. Keep the scorer behind a `ComplexityScorer` interface with two
  implementations: `HeuristicScorer` (default) and `LLMScorer` (uses the
  `complexity_classifier` prompt; falls back to the heuristic on any error).
- Tier thresholds come from config (e.g. `< 0.35` simple, `< 0.7` medium, else complex).
- **Tiers** (configured in YAML, not hard-coded):
  - `simple` → cheap fast model
  - `medium` → mid-range model
  - `complex` → most capable model
  Each tier has an ordered **fallback chain** of models, ideally across different providers.
- **Retries**: exponential backoff with jitter, for retryable errors only
  (rate limit, timeout, 5xx). Respect `Retry-After` when present. Max attempts configurable.
- **Fallback**: when retries for a model are exhausted, or the error is non-retryable but
  provider-specific (auth failure, provider down), move to the next model in the chain.
  Do not fall back on `BadRequestError` caused by the client's input.
- **Circuit breaker** per provider: after N consecutive failures, skip that provider for a
  cool-down period, then allow one trial request (half-open).
- Per-request overrides via headers: `X-Route-Tier` (force a tier), `X-No-Fallback: true`.
- Return the routing info in response headers: `X-Model-Used`, `X-Route-Tier`,
  `X-Fallback-Used`.

## Feature 4: Cost optimization tracking
- A pricing table in YAML: cost per 1M input tokens and per 1M output tokens for each model.
  Do not invent prices; use placeholder values clearly marked `# TODO: verify` and I will fill
  in current prices.
- For every request compute:
  - `actual_cost` = cost with the model actually used
  - `baseline_cost` = cost if the same tokens had gone to a configured **baseline model**
    (e.g. the most expensive model)
  - `savings` = `baseline_cost - actual_cost`, and savings percent
- Use `Decimal` for money, round only for display (6 decimal places, USD).
- Failed attempts that the provider still bills (if token counts are returned) count toward
  `actual_cost`.
- Send these to Langfuse as metadata/scores on the trace.
- Keep running totals (in memory by default, Redis optional via config) and expose:
  - `GET /v1/stats/costs` → total requests, total actual cost, total baseline cost,
    total savings, savings %, breakdown by model, tier, and agent ID
  - Optional query params: `since`, `agent_id`

---

## Technical specifications

### Configuration file: `config/models.yaml`
Model IDs below are placeholders. Replace with real IDs when configuring.

```yaml
baseline_model: complex-primary

providers:
  openai:    { api_key_env: OPENAI_API_KEY,    timeout_s: 60 }
  anthropic: { api_key_env: ANTHROPIC_API_KEY, timeout_s: 60 }
  gemini:    { api_key_env: GEMINI_API_KEY,    timeout_s: 60 }
  ollama:    { base_url_env: OLLAMA_BASE_URL,  timeout_s: 120 }

models:
  simple-primary:
    provider: openai
    model_id: <provider-model-id>
    pricing: { input_per_1m: 0.0, output_per_1m: 0.0 }   # TODO: verify
    max_context_tokens: 128000
    supports_tools: true
    supports_streaming: true
  # ... medium-primary, complex-primary, and fallbacks on other providers

routing:
  thresholds: { simple: 0.35, medium: 0.70 }
  tiers:
    simple:  [simple-primary, simple-fallback]
    medium:  [medium-primary, medium-fallback]
    complex: [complex-primary, complex-fallback]

retry:
  max_attempts: 3
  base_delay_s: 0.5
  max_delay_s: 8
  jitter: true

circuit_breaker:
  failure_threshold: 5
  cooldown_s: 30
```

Validate this file with Pydantic at startup. Unknown model names in tiers, missing pricing, or a
missing baseline model must fail startup with a clear message.

### API contract

**`POST /v1/chat/completions`**
Request body follows the OpenAI Chat Completions format: `model`, `messages`, `temperature`,
`max_tokens`, `top_p`, `stop`, `stream`, `tools`, `tool_choice`. Unsupported fields are ignored
with a debug log, not rejected.

Response body follows the OpenAI format (`id`, `object`, `created`, `model`, `choices`, `usage`)
plus a `gateway` object:
```json
"gateway": {
  "request_id": "req_...",
  "provider": "anthropic",
  "tier": "medium",
  "complexity_score": 0.52,
  "fallback_used": false,
  "attempts": 1,
  "cost": { "actual_usd": "0.000420", "baseline_usd": "0.002100", "savings_usd": "0.001680", "savings_pct": 80.0 }
}
```

Response headers: `X-Request-Id`, `X-Model-Used`, `X-Route-Tier`, `X-Fallback-Used`.

Streaming: SSE `data: {chunk}` lines in OpenAI chunk format, ending with `data: [DONE]`. The
final chunk before `[DONE]` includes `usage` and the `gateway` object. Fallback is only allowed
before the first token is sent; after that, a provider error ends the stream with an error event.

**`GET /v1/models`**: OpenAI-style list of configured models plus `"auto"`.

**`GET /v1/stats/costs`**: totals and breakdowns as described in Feature 4.

**`GET /health`**: always 200 if the process is up. **`GET /ready`**: 200 only if config and
prompts loaded and at least one provider has credentials; otherwise 503 with reasons.

### Error format
All errors use the OpenAI error shape so client SDKs parse them:
```json
{ "error": { "message": "...", "type": "rate_limit_error", "code": "all_providers_failed", "request_id": "req_..." } }
```

| Situation | HTTP status | `type` |
|---|---|---|
| Missing/invalid gateway key | 401 | `authentication_error` |
| Invalid request body | 400 | `invalid_request_error` |
| Unknown model name | 404 | `not_found_error` |
| All models in chain failed | 503 | `service_unavailable` |
| Upstream timeout, no fallback left | 504 | `timeout_error` |
| Gateway rate limit exceeded | 429 | `rate_limit_error` |

### Environment variables (`.env.example`)
```
GATEWAY_API_KEYS=key1,key2
LOG_LEVEL=INFO
MODELS_CONFIG_PATH=config/models.yaml
PROMPTS_DIR=prompts
PROMPT_SOURCE=local                 # local | langfuse
COMPLEXITY_SCORER=heuristic         # heuristic | llm
OPENAI_API_KEY=
ANTHROPIC_API_KEY=
GEMINI_API_KEY=
OLLAMA_BASE_URL=http://ollama:11434
LANGFUSE_PUBLIC_KEY=
LANGFUSE_SECRET_KEY=
LANGFUSE_HOST=
COST_STORE=memory                   # memory | redis
REDIS_URL=redis://redis:6379/0
RATE_LIMIT_PER_MINUTE=120           # per gateway key
UVICORN_WORKERS=2
```

### Non-functional requirements
- Gateway overhead (excluding provider time) under 20 ms p95 with the heuristic scorer.
- Timeouts on every outbound call; graceful shutdown drains in-flight requests.
- Per-gateway-key rate limiting (in memory by default, Redis when `COST_STORE=redis`).
- Request body size limit (configurable, default 1 MB).
- Provider API keys and gateway keys never appear in responses, logs or Langfuse.
- Message content is logged to Langfuse but **not** to stdout logs by default
  (`LOG_PROMPTS=false`).
- Note: in-memory cost totals are per worker. Document this, and recommend Redis when
  `UVICORN_WORKERS > 1`.

---

## Other endpoints and requirements
- **Auth**: agents send `Authorization: Bearer <gateway-key>`. Gateway keys come from env.
- All config via environment variables (`.env`) plus `config/models.yaml`.
  Provide `.env.example` with every variable documented.

## Project structure (suggested, adjust in your plan if needed)
```
app/
  main.py               # FastAPI app, lifespan, middleware
  api/                  # routes: chat, models, stats, health
  core/                 # settings, auth, logging, errors, rate limiting
  providers/            # base.py, openai.py, anthropic.py, gemini.py, ollama.py
  routing/              # complexity.py, router.py, retry.py, circuit_breaker.py
  prompts/              # loader.py, schemas.py, langfuse_source.py
  observability/        # langfuse_client.py
  cost/                 # pricing.py, tracker.py
  schemas/              # unified request/response models
config/models.yaml
prompts/                # runtime prompt YAML files (see Repository conventions)
docs/                   # specs, ADRs, architecture
.claude/commands/       # reusable Claude Code prompts
tests/
  unit/
  integration/
  fixtures/             # sample provider responses, sample prompts
Dockerfile
docker-compose.yml
.env.example
CLAUDE.md
README.md
```

## Docker
- Multi-stage `Dockerfile` on a slim Python base, non-root user, `HEALTHCHECK` hitting
  `/health`, Uvicorn with configurable workers.
- Copy `config/` and `prompts/` into the image; allow overriding both with volume mounts.
- `docker-compose.yml` with the `gateway` service, plus optional profiles for `redis`, `ollama`,
  and a self-hosted Langfuse stack (follow Langfuse's official self-hosting compose setup).
- `docker compose up` must start the gateway with only `.env` filled in.

## Tests (must pass)
- Unit: complexity scorer, router tier selection, retry/backoff logic, circuit breaker
  (closed → open → half-open), fallback order, cost and savings calculation, each provider's
  request/response mapping, config validation, prompt loader (versions, missing variables,
  invalid files, Langfuse fallback to local).
- Integration: `/v1/chat/completions` with mocked providers, covering success, retry then
  success, fallback to second provider, all providers failing (clean 503 with error detail),
  streaming, auth rejection, and rate limiting.
- No test may call a real provider API or a real Langfuse server.
- Target at least 85% line coverage on `app/routing`, `app/cost` and `app/prompts`.

## README
Explain setup, configuration, how routing decides, how to add a provider, how to add or change
a runtime prompt, how to read cost stats, example `curl` calls, and an example of pointing the
OpenAI Python SDK at the gateway by changing `base_url`. Link to `docs/specs/` and `docs/adr/`.

## Acceptance criteria
1. `docker compose up` starts the service, and `/health` returns 200.
2. A request with `model: "auto"` and a short prompt goes to the `simple` tier; a long
   code-analysis prompt goes to `complex`. Headers show which model was used.
3. When the first provider is mocked to fail, the response still succeeds via fallback, and
   Langfuse shows both attempts in one trace.
4. `/v1/stats/costs` shows actual cost, baseline cost, and savings that match a hand calculation.
5. With `COMPLEXITY_SCORER=llm`, the classifier prompt is loaded from `prompts/`, and its name
   and version appear in the Langfuse trace. Deleting a required variable from the template
   fails startup.
6. The OpenAI Python SDK works against the gateway by changing only `base_url` and `api_key`.
7. `CLAUDE.md`, at least four ADRs, `docs/architecture.md`, and the three `.claude/commands`
   files exist.
8. `pytest` passes, coverage targets are met, and `ruff check` is clean.

## Ways of working
- Ask me before adding any dependency not listed above.
- Keep functions small and typed; add docstrings for public classes.
- If something in this spec is unclear or contradictory, ask instead of guessing.
- When a requirement changes, update this spec file in the same change.
- After finishing, list anything left as TODO and any assumptions you made.
