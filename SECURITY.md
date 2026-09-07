# RecoverX — Security Notes

Last audited: Phase 15, via direct inspection of the source tree (not
generated from a template) — see findings and fixes below. Phase 14's
findings are preserved unchanged further down.

## Scope and threat model

This is a **local demo/hackathon build**, not production banking
infrastructure. It is explicitly:
- Single-user, no authentication (deliberately out of scope — see README)
- Simulation-only: no real payment, email, SMS, or ticketing system is ever
  contacted (enforced throughout — every simulated action's message says so
  explicitly, and mechanically verified via source inspection in every
  phase's test suite)
- No real customer data: the demo dataset is entirely synthetic (Phase 13)

## Phase 15 additions

- **No LLM credentials required, none hardcoded.** `recoverx/agent/provider.py`
  implements a `ReasoningProvider` interface. The default,
  `DeterministicReasoningProvider`, is fully offline — it composes the
  reasoning narrative from existing diagnosis/decision/customer data, no
  network call, no API key. A placeholder `EnvLLMReasoningProvider` exists
  for a future real LLM integration; it reads its key from the
  `RECOVERX_LLM_API_KEY` environment variable only (never hardcoded), and
  currently raises `NotImplementedError` rather than pretending to call a
  provider that isn't actually wired up. Selecting a provider (via the
  `RECOVERX_LLM_PROVIDER` env var, default `deterministic`) never changes
  the tests' network requirements — confirmed by `tests/test_phase15_agent.py`'s
  "no external network requirement" tests.
- **The AI agent cannot bypass the deterministic Policy/Guardrail layers.**
  `recoverx/guardrails/engine.py`'s `evaluate_guardrails()` can only narrow
  what the Policy Engine (Phase 5, unmodified) already allows — verified by
  `tests/test_phase15_guardrails.py::TestPhase15GuardrailsPolicyOverridesAgent`.
  The Simulator (Phase 6, unmodified) is still only ever called with a
  `PolicyDecision`-shaped `final_action`, never the agent's raw
  recommendation directly — see `_effective_policy_decision()` in
  `recoverx/api/agent_pipeline.py`.
- **CORS was widened from two hardcoded origins to a loopback-only regex**
  (`recoverx/api/app.py`): `allow_origin_regex=r"http://(localhost|127\.0\.0\.1):\d+"`,
  so a local Vite dev server can bind to any local port (avoiding collisions
  with other services) without needing the backend's CORS list edited by
  hand each time. Still restricted to `localhost`/`127.0.0.1` only — never
  a wildcard, and still explicitly documented as not a production
  configuration. `tests/test_phase15_api.py::test_cors_still_narrow_with_agent_router_installed`
  confirms exactly one CORS middleware instance is installed.
- **New routes audited the same way as Phase 14's:** `grep`-checked for
  `eval`/`exec`/`pickle`/`shell=True`/`os.system`/hardcoded secrets across
  `recoverx/agent/`, `recoverx/guardrails/`, `recoverx/explainability/`,
  `recoverx/audit/`, `recoverx/api/agent_pipeline.py`, `recoverx/api/routes/agent.py`
  — none found (also enforced by
  `tests/test_phase15_api.py::TestPhase15NoSecretsOrUnsafeCalls`).
- **Batch evaluation endpoint reuses the same cap as Phase 13's:**
  `GET /api/v1/agent/evaluation/report` rejects `n > 20,000` with HTTP 422,
  the same synchronous-request safety margin as `/api/v1/evaluation/report`.

## Findings from the Phase 14 audit (real, not hypothetical)

| Finding | Status |
|---|---|
| `.env` was not in `.gitignore` | **Fixed** — added `.env`/`.env.local` patterns. No `.env` file has ever existed in this backend (it reads zero environment variables — confirmed via `grep -rn "os.environ\|os.getenv" recoverx/`, no matches), so nothing leaked; this closes the gap before it could matter. |
| `frontend/` had no `.gitignore` at all | **Fixed** — added one covering `node_modules/`, `dist/`, `.env.local`. |
| `eval`/`exec`/`pickle`/`shell=True`/`os.system`/`subprocess` | None found anywhere in `recoverx/` |
| Hardcoded secrets/API keys | None found |
| Debug `print()` statements left in source | None found (only in test files, where they're intentional) |
| `TODO`/`FIXME`/placeholder `pass` stubs | None found |
| Stack traces leaking to API clients | Not possible by default — FastAPI returns a generic 500 for uncaught exceptions; every route that can raise a domain `ValueError` catches it explicitly and re-raises as `HTTPException` with a clean message |

## Input validation

Every API request body is a typed Pydantic model (no raw `dict`/`Any`
bodies anywhere) — verified by inspection of every route file. Domain-level
validation (Phase 1's `Transaction`/`Customer`, Phase 8's `CheckoutSession`)
is never bypassed by the API layer: invalid data raises `ValueError` at
model construction, caught and returned as HTTP 422.

## CORS

Configured narrowly for local development only — `http://localhost:5173`
and `http://localhost:3000`. **Not** a wildcard, and explicitly documented
in `recoverx/api/app.py` as not being a production configuration. Update
this before deploying anywhere beyond local/demo use.

## Dependencies

`requirements.txt` pins version ranges (not exact versions) for `fastapi`,
`uvicorn`, `pydantic`, `httpx` — no dependency has been added without being
actually used (confirmed by re-reading `requirements.txt`'s own comments,
which document what each phase actually needs).

## Known, accepted limitations (by design, not oversights)

- **No authentication/authorization.** Documented scope decision since
  Phase 7 — this is a local/demo tool, and adding auth infrastructure was
  explicitly out of scope for every phase.
- **In-memory result store, no persistence.** Documented since Phase 7 —
  results don't survive a server restart. Not a security issue, but worth
  knowing before treating this as anything beyond a demo.
- **No rate limiting.** Acceptable for a local/demo deployment; would need
  adding before any public-facing use.
