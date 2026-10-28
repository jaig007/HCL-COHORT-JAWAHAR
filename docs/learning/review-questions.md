# Review questions

Quick-check questions from each lab. Try to answer first, then open "Answer" to check.

---

## Overview: what an LLM gateway is

**Q1.** An agent sends "What is 2 + 2?" with `model: "auto"`. Which tier does it go to, and why?

<details><summary>Answer</summary>

The `simple` tier. The complexity scorer gives a short prompt with no code, no reasoning
keywords and only one message a low score (below 0.35), so it goes to the cheap, fast model.
</details>

**Q2.** The gateway gets a "rate limit" error from OpenAI. Which feature decides what happens next, and what might it do?

<details><summary>Answer</summary>

Feature 3 (routing, retries and fallback). A rate limit is retryable, so the gateway waits
(exponential backoff with jitter, respecting `Retry-After`) and tries again. If retries run
out, it falls back to the next model in the tier's chain. After many failures in a row, the
circuit breaker skips OpenAI for a cool-down period.
</details>

---

## Setup: virtual environment and project files

**Q1.** Why do we commit `requirements.txt` to git but put `.venv` in `.gitignore`?

<details><summary>Answer</summary>

`requirements.txt` is a small, readable list of what the project needs, so anyone can
rebuild the environment with `pip install -r requirements.txt`. `.venv` is large, full of
generated files, and tied to one machine and OS, so it should be recreated, not shared.
</details>

**Q2.** Why is `.env` in `.gitignore`, and what could go wrong if it were committed?

<details><summary>Answer</summary>

`.env` holds real secrets such as API keys. If it were committed, anyone with access to the
repo (or the public, if it is pushed to GitHub) could use your keys and run up costs.
Removing it later does not help, because it stays in git history. The key must be revoked.
</details>

---

## Lab 1: smallest FastAPI app

**Q1.** You set `LOG_LEVEL=DEBUG` in `.env`, and you also run `$env:LOG_LEVEL="ERROR"` in PowerShell before starting the server. Which value does the app use, and why?

<details><summary>Answer</summary>

`ERROR`. In pydantic-settings, real environment variables take priority over values in the
`.env` file. `.env` only fills in what is not already set.
</details>

**Q2.** Why do we have both `/health` and `/ready` instead of just one endpoint?

<details><summary>Answer</summary>

They answer different questions. `/health` asks "Is the process alive?"; if it fails, the
platform should restart the container. `/ready` asks "Can it serve requests right now?"
(config loaded, provider keys present); if it fails, traffic should not be sent to it, but a
restart may not help.
</details>

---

## Lab 2: Docker

**Q1.** Why does the Dockerfile copy `requirements.txt` and run `pip install` *before* copying the `app/` folder?

<details><summary>Answer</summary>

Layer caching. Docker reuses a cached step if its inputs did not change, but once one step
changes, every step after it is rebuilt. Code changes often and requirements rarely, so
installing packages first means a code edit only redoes the fast "copy app/" step and skips
the slow `pip install`. Rule of thumb: rarely-changing steps near the top, often-changing
near the bottom.
</details>

**Q2.** Inside the container, Uvicorn listens on `0.0.0.0` instead of `127.0.0.1`. What would happen if it used `127.0.0.1`?

<details><summary>Answer</summary>

The server would start, but you could not reach it from your computer, even with the
`8000:8000` port mapping. A container has its own network, and `127.0.0.1` there means "only
the container itself". Docker forwards your traffic to the container's network interface,
which `0.0.0.0` listens on. The tricky part: the `HEALTHCHECK` would still report
*healthy*, because it calls `127.0.0.1` from inside the container.
</details>
