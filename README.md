# RecoverX — AI Revenue Recovery Agent (Phases 1–15, complete)

AI-powered Revenue Leak Detection & Recovery Agent (Razorpay Buildathon, Track 03).

**Status: Phases 1–15 complete.** RecoverX runs the full
DETECT → DIAGNOSE → REASON → DECIDE → GUARD → ACT → VERIFY → MEASURE → AUDIT
pipeline: a deterministic risk/diagnosis/decision/policy/simulation core
(Phases 1–8), a human-in-the-loop approval workflow, analytics, a what-if
simulator, and a synthetic-data batch evaluation (Phases 9–13), a security
pass and Docker packaging (Phase 14), and — on top of all of that, unchanged
— an AI reasoning agent, explicit guardrails, explainability, and an audit
timeline (Phase 15). See the "Phase 15" section below for the newest layer,
and each phase's own section for how it was built incrementally.

This README is written phase-by-phase, in the order the project was actually
built — that history is kept intentionally (it documents *why* each design
choice was made, not just what exists today), rather than being collapsed
into a single "final architecture" description.

## What's here

- `recoverx/models/` — five validated dataclasses: `Customer`, `Transaction`,
  `RecoveryCase`, `RecoveryAction`, `AuditLog`. Invalid data raises `ValueError`
  immediately at construction time.
- `recoverx/database/db.py` — a plain `sqlite3` persistence layer (no ORM yet).
  Foreign keys are enforced at the database level via business keys
  (`customer_id`, `transaction_id`, `case_id`).
- `tests/test_phase1.py` — the 10 required Phase 1 tests.

## Running the tests

```bash
# from the repository root
python3 -m unittest tests.test_phase1 -v
```

Expected: `Ran 10 tests in 0.0Xs` / `OK`. (To run every phase's tests
together, see "Running the tests" under Phase 7, or just run
`python3 -m unittest discover -s tests -v` from the repository root.)

## Design notes

- `id` on every model is the internal database primary key (auto-assigned on
  insert, `None` before that). Every cross-model reference uses the *business*
  key instead (`customer_id`, `transaction_id`, `case_id`) — this mirrors how a
  real merchant integration would reference records, and lets the model layer
  stay independent of the database layer.
- The database layer explicitly checks that a referenced business key exists
  before inserting a dependent row (e.g. you cannot insert a `Transaction` for
  a `customer_id` that hasn't been created), in addition to SQLite's own
  `FOREIGN KEY` constraint — this gives a clear `ValueError` instead of a raw
  SQLite error.
- Tests use an in-memory database (`get_test_database()`) so they never touch
  disk or leak state between runs.

## Phase 2 — Revenue Risk Engine

`recoverx/risk_engine/engine.py` — a pure function `assess_risk(transaction, customer=None) -> RiskAssessment`.
Deterministic, explainable, decoupled from the database (takes plain model objects, not DB rows).

**Methodology:** the 0–100 score is the sum of five weighted, documented components
(amount, failure reason, customer history, retry count, payment method — weights
sum to 100). See the constants block at the top of `engine.py` for exact weights
and the reasoning behind each. Risk levels: `HIGH >= 60`, `MEDIUM >= 30`, `LOW < 30`.

Special cases (both return `risk_score=0`, `revenue_at_risk=0`, with an explanation):
- Transaction already succeeded — nothing is at risk.
- Customer has opted out — excluded from active recovery regardless of other factors.

```bash
python3 -m unittest tests.test_phase2 -v
```

## Phase 3 — Diagnosis Engine

`recoverx/diagnosis/engine.py` — `diagnose(transaction, customer=None, risk_assessment=None) -> DiagnosisResult`.
Answers "what is wrong?" only — never selects a recovery action (that's Phase 4).
Deterministic, explainable, does not import `sqlite3` or `recoverx.database` (enforced by an AST-based test, not just a docstring promise).

**Root causes:** `TEMPORARY_PAYMENT_FAILURE`, `EXPIRED_PAYMENT_METHOD`, `INSUFFICIENT_FUNDS`,
`INVALID_PAYMENT_DETAILS`, `BANK_UNAVAILABLE`, `CHECKOUT_ABANDONMENT`, `UNKNOWN`,
plus the special status `NO_ACTIVE_FAILURE` for already-succeeded transactions.

**Confidence** is a rule-based trust score (NOT a trained ML probability — that comes later):
starts from a per-root-cause base value, then adjusted down if retries undermine a
"temporary" classification, or if customer history is too thin to lean on. Always clipped to `[0.0, 1.0]`.

```bash
python3 -m unittest tests.test_phase3 -v
```

## Phase 4 — Recovery Decision Engine

`recoverx/decision/engine.py` — `decide(transaction, diagnosis, customer=None, risk_assessment=None) -> DecisionResult`.
Answers "what should we try?" — a **recommendation only**. Never executes anything,
never sets an authorization/approval field (enforced by a test inspecting the
dataclass fields directly), never imports the database.

**Recovery probability** is a rule-based estimate per (root cause, action) pair,
adjusted for retry count (decays `RETRY_PAYMENT`/`WAIT_AND_RETRY` probability, and
excludes `RETRY_PAYMENT` entirely once `retry_count >= 3`) and customer history
(±0.08 for strong/weak history with ≥3 past payments) — explicitly NOT `risk_score / 100`.

**Economics:** `expected_recovery = amount × recovery_probability`,
`expected_net_recovery = expected_recovery − intervention_cost`. Intervention costs
are documented simulation constants (`RETRY_PAYMENT`=₹5 … `ESCALATE_TO_HUMAN`=₹150;
`OFFER_LIMITED_INCENTIVE`=5% of amount) — explicitly not real payment-provider pricing.
The engine picks the candidate action with the highest `expected_net_recovery`
among plausible options for the diagnosed root cause — optimizing net recovery,
not retry count, per the project's core principle.

**Overrides** (bypass the EV ranking on purpose): already-succeeded → `NO_ACTION`;
opted-out customer → `DO_NOT_CONTACT`; diagnosis confidence < 0.5 → `ESCALATE_TO_HUMAN`.

```bash
python3 -m unittest tests.test_phase4 -v
```

## Phase 5 — Policy & Safety Engine

`recoverx/policy/engine.py` — `evaluate_policy(transaction, decision, customer=None, diagnosis=None, risk_assessment=None) -> PolicyDecision`.
The safety gate between "we want to do this" (Decision Engine) and "we're allowed
to do this." Never executes anything, never mutates its inputs, never touches the database.

**Evaluation order** (a rule earlier in this list always wins over economics, even a
huge expected net recovery — see `test_17_safety_rules_override_high_expected_value`):
1. Invalid/unsupported action → BLOCK
2. Terminal case (already successful) → BLOCK, final_action=`NO_ACTION`
3. Opt-out protection (customer-contact actions only: `SEND_PAYMENT_LINK`, `SEND_REMINDER`, `OFFER_LIMITED_INCENTIVE`) → BLOCK
4. Retry limit (`retry_count >= MAX_AUTOMATED_RETRIES`) → BLOCK, escalate
5. High-value (`amount >= HIGH_VALUE_THRESHOLD`) automated action → ESCALATE
6. Low decision confidence (`< LOW_CONFIDENCE_THRESHOLD`) → ESCALATE
7. Incentive over `MAX_INCENTIVE_PERCENT` → MODIFY (capped)
8. Otherwise → ALLOW

Config constants: `MAX_AUTOMATED_RETRIES=3`, `HIGH_VALUE_THRESHOLD=₹50,000`,
`LOW_CONFIDENCE_THRESHOLD=0.5`, `MAX_INCENTIVE_PERCENT=5%`.

```bash
python3 -m unittest tests.test_phase5 -v
```

## Phase 6 — Recovery Action Simulator

`recoverx/simulator/simulator.py` — `simulate(policy_decision, transaction, customer=None, decision=None) -> SimulationResult`.
A safe, entirely offline simulation of "what would happen if the policy-approved
action ran." **No real payment gateway, bank, email, SMS, or ticketing system is
ever contacted** — every result is explicitly labeled SIMULATED in its message.

**Critical safety rule:** the simulator takes a `PolicyDecision`, not a raw
`DecisionResult`, and always acts on `policy_decision.final_action`. A
`DecisionResult` may optionally be passed for context (recovery-probability-based
retry outcomes, cost consistency) but is never authoritative for *which* action
runs — this is what stops Phase 6 from bypassing Phase 5.

**Supported actions:** all 8 from the catalogue (`RETRY_PAYMENT`, `WAIT_AND_RETRY`,
`SEND_PAYMENT_LINK`, `SEND_REMINDER`, `OFFER_LIMITED_INCENTIVE`, `ESCALATE_TO_HUMAN`,
`DO_NOT_CONTACT`, `NO_ACTION`). Only `RETRY_PAYMENT`/`WAIT_AND_RETRY` simulate an
actual payment outcome (deterministically, from `recovery_probability >= 0.5` when
available); the contact-based actions simulate only the *sending* of the
intervention (a fake `simulation://payment-link/<id>` URL, a generated-not-sent
reminder, a capped simulated incentive) — actual downstream recovery from those is
out of this phase's scope.

**Safety:** a recovery-attempt action only runs if `policy_decision.allowed` is
`True` (defense-in-depth, checked independently of what upstream decided); blocked/
escalated cases produce `status=BLOCKED`/zero recovery without ever touching the
action logic. Simulation IDs are deterministic (`sha256` of transaction+action+cost),
so the same approved action always produces the same identity — useful for
idempotency later.

```bash
python3 -m unittest tests.test_phase6 -v
```

## Phase 7 — Application API + End-to-End Pipeline

**Architecture:** `API → run_recovery_pipeline() → Risk → Diagnosis → Decision → Policy → Simulator → API response`.
`recoverx/api/pipeline.py` (`run_recovery_pipeline()`) is the **only** orchestration
function — it calls the five verified engines in order and contains no business
logic of its own (mechanically checked: `test_orchestrator_has_no_business_logic_of_its_own`).
The API layer (`recoverx/api/app.py`, `routes/recovery.py`, `schemas/recovery.py`)
is a thin wrapper: it maps a request to `Transaction`/`Customer`, calls the
orchestrator, and maps the result to a response — it never recomputes risk,
diagnosis, decisions, or policy.

**Split by dependency, so the core is always testable:**
- `recoverx/api/pipeline.py` — pure Python, stdlib only, no framework dependency.
- `recoverx/api/app.py` / `routes/` / `schemas/` — require `fastapi` + `pydantic` (see `requirements.txt`).

### Endpoints

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/api/v1/health` | Liveness check |
| POST | `/api/v1/recovery/analyze` | Run the full pipeline for one transaction |
| GET | `/api/v1/recovery/{transaction_id}` | Retrieve the most recent result for a transaction (in-memory, this process only — see docstring in `routes/recovery.py` for why this isn't SQLite-backed yet) |

### Running the API

```bash
pip install -r requirements.txt
uvicorn recoverx.api.app:app --reload
```

Then visit `http://127.0.0.1:8000/docs` for interactive API docs (auto-generated).

Example request:
```bash
curl -X POST http://127.0.0.1:8000/api/v1/recovery/analyze \
  -H "Content-Type: application/json" \
  -d '{
    "customer": {"customer_id": "CUST-001", "past_success_count": 8, "past_failure_count": 1, "opted_out": false},
    "transaction": {"transaction_id": "TXN-001", "customer_id": "CUST-001", "amount": 4999, "status": "failed", "failure_reason": "temporary_bank_failure", "retry_count": 0, "payment_method": "card"}
  }'
```

**Safety:** every response's `simulation.message` explicitly says "SIMULATED" —
no real payment, message, or ticket is ever created. CORS is restricted to
local dev origins only (`localhost:5173`/`3000`), not production-open.

### Testing

```bash
# Core pipeline (pure Python, no install needed — always runs):
python3 -m unittest tests.test_phase7_pipeline -v

# API layer (needs fastapi/pydantic/httpx installed):
pip install -r requirements.txt
python3 -m unittest tests.test_phase7_api -v
```

## Phase 8 — Checkout Abandonment Recovery

**New:** `recoverx/checkout/` (`CheckoutSession` model + `detect_abandonment()`), plus
`run_checkout_abandonment_pipeline()` in `recoverx/api/pipeline.py`. Reuses the
**exact same** Risk → Diagnosis → Decision → Policy → Simulator engines as
failed-payment recovery — no second pipeline, no duplicated logic.

**How reuse works:** once a checkout is genuinely abandoned, a synthetic
`Transaction` is built (`status="failed"`, `failure_reason="customer_abandoned"`
— a value the Diagnosis Engine already maps to `CHECKOUT_ABANDONMENT`), then
passed to the unchanged `run_recovery_pipeline()`. Zero changes to Diagnosis
or Decision were needed.

**Detection:** `detect_abandonment(checkout, reference_time)` — deterministic,
takes an explicit reference time (never `datetime.now()` internally).
`ABANDONMENT_THRESHOLD_MINUTES = 30`. Distinguishes: active (not yet abandoned),
completed (`payment_status="success"`), failed payment attempt (`"failed"` —
excluded, belongs to the other workflow), and genuinely abandoned (no payment
ever attempted, inactive beyond the threshold). Abandonment reason is limited
to what the minimal data model can actually prove: `PAYMENT_NOT_ATTEMPTED` or
`UNKNOWN` — never a fabricated cause like "found the price too high."

**Two small, necessary, documented changes to previously-verified code** (both rerun against full regression):
- `Transaction.payment_method` gained `"unknown"` — a checkout with no payment attempt has no known method.
- Policy Engine gained a new rule, `MAX_CONTACT_ATTEMPTS = 2` — throttles repeated `SEND_REMINDER`/`SEND_PAYMENT_LINK`/`OFFER_LIMITED_INCENTIVE` attempts (Phase 5 only ever throttled `RETRY_PAYMENT`). Applies to both workflows.

**Safety:** opted-out customers still get `DO_NOT_CONTACT`; high-value abandoned
checkouts still escalate; repeated recovery attempts are blocked by the new
policy rule — all via the existing Policy Engine, never bypassed.

```bash
python3 -m unittest tests.test_phase8 -v
```

## Phase 9 — Frontend Dashboard (vertical slice)

`frontend/` — React + TypeScript + Vite + Tailwind. **Scope call, documented:**
one focused page with both workflows (Failed Payment / Checkout Abandonment),
not all 8 pages from the original product spec — vertical-slice discipline
applied to the frontend, matching how the backend was built phase by phase.
The other 7 dashboard pages (Recovery Queue, Case Details, Agent Activity,
Analytics, What-If Simulator, Audit Log, Human Approval) are deferred to a
later phase.

**Design:** a "ledger" aesthetic (`tailwind.config.js`) — cool slate/navy
structure, IBM Plex Sans (UI) + IBM Plex Mono (every number and ID, so money
and simulation IDs read like a ledger). Signature element: `PipelineRail.tsx`,
a literal 5-node rail (Detect→Diagnose→Decide→Policy→Simulate) that colors
each node by real outcome — earned here because the product genuinely is a
sequential pipeline with one hard safety gate (Policy), not decoration.

**Structure:**
```
frontend/src/
├── types/recovery.ts       # mirrors the FastAPI schemas field-for-field
├── api/client.ts            # thin fetch wrapper, zero business logic
├── utils/format.ts          # pure helpers (currency formatting, status→tone)
├── components/              # PipelineRail, PipelineResultView, forms, etc.
└── App.tsx                  # composes both workflows, loading/error/success states
```

**Wiring:** both forms call the real Phase 7/8 endpoints
(`POST /recovery/analyze`, `POST /recovery/checkout-abandonment/analyze`) via
`api/client.ts`. Loading, error (including field-level 422 validation
details), and success states are all handled explicitly in `App.tsx`.

### Verification status

As originally built (Phase 9), this sandbox had no network access, so
`npm install` could not be run; type-checking and syntax were verified by
other means at the time. That limitation no longer applies: from Phase 14
onward, `npm install`, `npm run build` (`tsc -b && vite build`), and
`npm run test` (`vitest run`) have all been run for real in this
environment and pass — see the Phase 15 "Testing" section for current,
actually-executed frontend test counts.

### Running it locally

```bash
cd frontend
npm install
npm run test    # runs the 16 format.ts unit tests
npm run build   # full type-check + production build
npm run dev      # starts on http://localhost:5173
```
Make sure the backend is running first (`uvicorn recoverx.api.app:app --reload`, see Phase 7) — CORS is already configured for `localhost:5173`.

## Phase 10 — Human-in-the-Loop Approval

`recoverx/approval/` — `apply_human_approval(pipeline_result, transaction, customer, approval) -> PipelineResult`.
Lets a human approve or reject a case the Policy Engine **escalated**
(`policy.escalation_required == True` — high-value or low-confidence cases).

**Key design point, zero changes to Phases 1–9:** a human approval is modeled
as a *new* `PolicyDecision` — the human's judgment standing in for the
automated one — run through the exact same, unmodified `simulate()`. Approving
sets `final_action` to the **original Decision Engine recommendation** and
re-simulates it for real; rejecting sets `final_action = DO_NOT_CONTACT` and
records who rejected it and why. Risk/Diagnosis/Decision are untouched — the
human is reviewing the recommendation, not re-diagnosing the transaction.

**Deliberately restricted scope:** only `ESCALATE` cases are approvable.
Cases the Policy Engine **BLOCK**ed (opt-out, retry-limit, terminal,
invalid-action) are hard safety rules, not judgment calls — attempting to
approve/reject one raises `ValueError` (404/409 at the API layer) rather than
allowing a safety bypass through this workflow.

**API (additive to the existing router, same in-memory store extended, not duplicated):**

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/api/v1/recovery/pending-approvals` | List cases awaiting human review |
| POST | `/api/v1/recovery/{transaction_id}/approve` | Approve (`approved: true`) or reject (`false`) |

```bash
python3 -m unittest tests.test_phase10 -v       # core engine, runs without any dependencies
python3 -m unittest tests.test_phase10_api -v   # API layer, needs fastapi/pydantic/httpx
```

## Phase 11 — Analytics

`recoverx/analytics/engine.py` — `summarize(results: Iterable[PipelineResult]) -> AnalyticsSummary`.
Pure aggregation (totals + breakdowns by root cause / final action / risk
level / policy decision) over whatever `PipelineResult`s it's given —
decoupled from storage, so it doesn't know or care where they came from.

**API:** `GET /api/v1/analytics/summary`, reading from the same in-memory
store used for retrieval/approval since Phase 7/10 (now extracted to
`recoverx/api/store.py` so multiple routers can share it cleanly).

**A real bug found and fixed during this phase:** the checkout-abandonment
route (`/recovery/checkout-abandonment/analyze`) was never storing its
results — only the failed-payment route was. Every checkout-abandonment case
would have been silently invisible to analytics (and to retrieval/approval).
Fixed by exposing the synthetic `Transaction` from `CheckoutPipelineResult`
(small, additive field) and storing both workflows' results the same way.

All figures are aggregates of **simulated** outcomes — field names
(`simulated_recovery`, not `recovered`) and the per-case `simulation.message`
disclosures both make this explicit; this endpoint never claims real-world
financial totals.

```bash
python3 -m unittest tests.test_phase11 -v       # core engine, no dependencies needed
python3 -m unittest tests.test_phase11_api -v   # API layer, needs fastapi/pydantic/httpx
```

## Phase 12 — What-If Strategy Simulator

`recoverx/whatif/engine.py` — `compare_strategies(transaction, customer=None) -> list[WhatIfOption]`.
Ranks every recovery strategy plausible for a transaction's diagnosed root
cause by expected net recovery, each annotated with whether the **real**
Policy Engine would actually allow it. **Read-only and hypothetical** — never
calls the Simulator, never executes anything, never mutates its inputs
(mechanically verified: no `simulate` import, AST-checked, plus an explicit
mutation test).

**Zero new business logic.** One small public wrapper was added to the
verified Phase 4 Decision Engine — `compare_all_candidates()` — which reuses
the exact same private candidate-building and estimation helpers `decide()`
already calls internally; it just returns the full ranking instead of only
the top pick + top-3 alternatives. Everything else (Risk, Diagnosis, Policy)
is called completely unmodified. Each option's policy feasibility is checked
by constructing a synthetic `DecisionResult` for that one hypothetical choice
and running it through the real `evaluate_policy()` — this is never stored
or returned as if it were an actual recommendation.

```bash
python3 -m unittest tests.test_phase12 -v       # core engine, no dependencies needed
python3 -m unittest tests.test_phase12_api -v   # API layer, needs fastapi/pydantic/httpx
```

Example (real output, ₹4,999 temporary failure, strong history):

| Action | Probability | Expected recovery | Cost | Net | Policy |
|---|---|---|---|---|---|
| RETRY_PAYMENT | 0.83 | ₹4,149.17 | ₹5.00 | ₹4,144.17 | ALLOW |
| WAIT_AND_RETRY | 0.78 | ₹3,899.22 | ₹5.00 | ₹3,894.22 | ALLOW |
| SEND_PAYMENT_LINK | 0.63 | ₹3,149.37 | ₹15.00 | ₹3,134.37 | ALLOW |
| ESCALATE_TO_HUMAN | 0.40 | ₹1,999.60 | ₹150.00 | ₹1,849.60 | ALLOW |

## Phase 13 — Synthetic Dataset + Evaluation + Baseline Comparison

`recoverx/dataset/generator.py` — `generate_synthetic_dataset(n=5000, seed=42)`.
Deterministic (seeded `random.Random` instance, never the global `random`
module — mechanically verified). Realistic, documented correlations:
customers drawn from three profiles (loyal/new/problem) with different
history distributions; failure reasons weighted per profile; amounts drawn
from three weighted bands; ~8% already-successful, ~4% opted-out. **No
outcome labels are fabricated** — "ground truth" is whatever the real,
deterministic pipeline computes when a case is run, never invented upfront.

`recoverx/evaluation/engine.py` — `evaluate(cases) -> EvaluationReport`.
Compares a naive **"always retry once, no policy checks" baseline** against
the full RecoverX pipeline, both using the *same* deterministic outcome
mechanics (Phase 6) for a fair comparison.

### A real, important finding from actual execution (not hidden)

On the full 5,000-case synthetic dataset: baseline net ≈ **₹40.8M**, RecoverX
net ≈ **₹6.6M** — RecoverX recovers *less* raw simulated revenue than the
unsafe baseline. This is **expected, not a bug**, for two structural reasons,
both by design since Phase 6:
1. Only `RETRY_PAYMENT`/`WAIT_AND_RETRY` ever simulate a nonzero recovery
   outcome — sending a payment link/reminder/incentive doesn't fabricate a
   guess about whether the customer later pays. The baseline *always*
   retries; RecoverX often correctly picks a non-retry action.
2. Escalated/blocked cases (**40.5% of cases, ₹121M of revenue** in the full
   run) show ₹0 recovered — RecoverX defers those to a human rather than
   guessing, while the naive baseline blindly retries high-value and
   retry-exhausted transactions and gets simulated credit for it.

`EvaluationReport.recoverx_by_policy_decision` makes this breakdown visible
rather than folding it into one misleading number — see the field's
docstring for the full explanation. **This evaluation is best read as "how
much of a return-on-safety tradeoff are we making," not "which strategy
wins on raw ₹."**

```bash
python3 -m unittest tests.test_phase13 -v       # core (dataset + evaluation), no dependencies needed
python3 -m unittest tests.test_phase13_api -v   # API layer, needs fastapi/pydantic/httpx
```

`GET /api/v1/evaluation/report?n=1000&seed=42` — generates and evaluates on demand (capped at 20,000 cases for a synchronous request; 5,000 cases run in ~0.3s locally).

## Phase 14 — Security/QA Pass, Docker, Deployment Prep, Final Docs

**Security audit** (real findings, see `SECURITY.md`): found and fixed two
real gaps — `.env` was never in `.gitignore` (though no `.env` file has ever
existed here; this backend reads zero environment variables, confirmed by
grepping for `os.environ`/`os.getenv`), and `frontend/` had no `.gitignore`
at all (now added, covering `node_modules/`, `dist/`, `.env.local`).
Everything else audited clean: no `eval`/`exec`/`pickle`/`shell=True`, no
hardcoded secrets, no debug prints or TODO stubs left in source, every API
body is a typed Pydantic model, CORS is narrowly scoped to local dev.

**Docker**: `Dockerfile` (backend — single Python image, no DB/LLM service
needed since this build has neither), `frontend/Dockerfile` (multi-stage
Vite build → nginx), `docker-compose.yml` orchestrating both. ⚠️ Docker
itself isn't installed in the sandbox this was built in — YAML syntax and
path correctness were verified mechanically, but `docker compose up --build`
is **UNVERIFIED — REQUIRES LOCAL EXECUTION**.

**Final docs**: `SECURITY.md` (audit findings), `DEMO.md` (quickstart, demo
flow, real 5,000-case evaluation numbers, 5-minute pitch structure) — all
figures pulled from actually running the evaluation, not invented.

## Phase 15 — AI Reasoning Agent, Guardrails, Explainability, Audit Timeline, Batch Evaluation

Phase 15 upgrades RecoverX from a good revenue-recovery pipeline into an
**AI Revenue Recovery Agent** for the Razorpay AI Buildathon, without
rewriting anything from Phases 1–14. Every new module is additive: the
existing `/api/v1/recovery/*`, `/api/v1/analytics/*`, `/api/v1/whatif/*`,
and `/api/v1/evaluation/report` endpoints, and every engine that backs
them, are completely unchanged and untouched.

**Core principle:** *the AI agent recommends; deterministic guardrails
control what it is actually allowed to do.* The AI never bypasses the
existing Policy/Safety Engine (Phase 5) — it can only be *further*
restricted by the new Guardrail layer, never widened past what Policy
already allows.

### Architecture

```
PAYMENT EVENT
     │
     ▼
REVENUE RISK ENGINE (Phase 2, unchanged)
     │
     ▼
DIAGNOSIS ENGINE (Phase 3, unchanged)
     │
     ▼
AI AGENT / REASONER (Phase 15, NEW)         — recoverx/agent/
  reuses Diagnosis + Decision exactly,
  adds only a reasoning narrative +
  alternative-action scores
     │
     ▼
DECISION ENGINE (Phase 4, unchanged)
     │
     ▼
POLICY / SAFETY ENGINE (Phase 5, unchanged)
     │
     ▼
GUARDRAILS (Phase 15, NEW)                  — recoverx/guardrails/
  9 explicit stopping rules; can only
  narrow what Policy already allowed
     │
   ┌─┴──────────┐
   ▼            ▼
ALLOWED       BLOCKED
   │            │
   ▼            ▼
SIMULATOR   STOP + AUDIT
(Phase 6, unchanged)
   │
   ▼
VERIFY → MEASURE
   │
   ▼
EXPLAINABILITY (Phase 15, NEW)    — recoverx/explainability/
AUDIT TIMELINE (Phase 15, NEW)    — recoverx/audit/
```

### New backend modules

- **`recoverx/agent/`** — the AI Diagnosis/Reasoning Agent. `run_agent()`
  reuses `assess_risk()`, `diagnose()`, and `decide()` exactly (no
  duplicated business logic) and adds a `reasoning` narrative plus
  `alternative_actions` scores. The reasoning text comes from a pluggable
  `ReasoningProvider` (`recoverx/agent/provider.py`): the default
  `DeterministicReasoningProvider` is fully offline and reproducible — no
  API key, no network call, works identically in tests, Docker, and the
  live demo. A placeholder `EnvLLMReasoningProvider` documents how a real
  LLM could be wired in later (via `RECOVERX_LLM_API_KEY`), without ever
  claiming one is used today.
- **`recoverx/guardrails/`** — explicit stopping rules
  (`evaluate_guardrails()`), checked against a configurable
  `MerchantRecoveryPolicy` (max retries, minimum recovery probability,
  minimum expected recovery value, allowed actions, opt-out protection,
  automatic-action toggle — all with safe defaults). Stops the pipeline
  when: payment already succeeded, customer opted out, max retries
  reached, failure is permanent, recovery probability or expected value is
  below threshold, the action isn't policy-allowed, required data is
  missing, or the same action already hit its attempt limit. Guardrails
  can only *narrow* the Policy Engine's decision, never widen it.
- **`recoverx/explainability/`** — `explain()` answers "why did the agent
  choose this?" with structured, traceable reasons and a scored list of
  alternative actions (selected action always among the candidates, no
  fabricated evidence).
- **`recoverx/audit/`** — `build_audit_timeline()` builds a chronological
  list of `AuditLog` entries (the *same* Phase 1 model, not a new one)
  covering every stage: DETECT, RISK_ASSESSED, AI_DIAGNOSIS, DECISION,
  POLICY, GUARDRAIL_CHECK, ACTION, VERIFY, MEASURE, PIPELINE.
- **`recoverx/api/agent_pipeline.py`** — the Phase 15 orchestrator,
  `run_agent_recovery_pipeline()`. Mirrors `run_recovery_pipeline()`'s
  structure but layers the AI Agent + Guardrails + Explainability + Audit
  on top. `_effective_policy_decision()` folds any further guardrail
  narrowing into a `PolicyDecision`-shaped object so the unmodified
  Simulator is still only ever called the same way it always has been.
- **`recoverx/evaluation/agent_evaluation.py`** — `evaluate_agent()` runs
  the full Phase 15 pipeline over a batch of cases (reusing Phase 13's
  synthetic dataset generator, unmodified) and reports: total cases,
  revenue at risk, eligible cases, recovery attempts, successful
  recoveries, recovery rate, revenue recovered, revenue recovery
  percentage, blocked actions, customer opt-outs, stopped cases, average
  recovery value. Precision/Recall/F1/ROC-AUC are **deliberately omitted**
  — this synthetic dataset has no fabricated "should have recovered"
  ground-truth label to grade against, and inventing one would violate
  this project's own no-fabrication principle.

### New API (all additive, under `/api/v1/agent/*`)

| Method & path | Purpose |
|---|---|
| `POST /api/v1/agent/analyze` | Run the full Phase 15 pipeline for one transaction |
| `GET /api/v1/agent/{transaction_id}` | Retrieve the most recent result for a transaction |
| `GET /api/v1/agent/{transaction_id}/explain` | "Why did the agent choose this?" |
| `GET /api/v1/agent/{transaction_id}/audit-timeline` | Full audit event list |
| `GET /api/v1/agent/policy/config` | Current `MerchantRecoveryPolicy` defaults |
| `GET /api/v1/agent/evaluation/report` | Batch evaluation (`?n=5000&seed=42`) |

Every existing `/api/v1/recovery/*` endpoint is unchanged — verified by
`tests/test_phase15_api.py`'s backward-compatibility tests.

### New frontend (AI Agent tab)

A third tab, **"AI Agent (Phase 15)"**, added alongside the two existing
Phase 7/8 workflows without changing them: `Hero` (problem/solution/trust
statement), `ScenarioPicker` (four one-click demo scenarios — see below),
the same `TransactionForm` wired to the new `/agent/analyze` endpoint,
`AgentPipelineResultView` (risk → deterministic diagnosis → AI reasoning →
guardrails → decision → "why this action" → simulation → audit timeline),
and, always visible below, `MoneyRecoveredDashboard` (the batch
evaluation's headline **₹ Revenue Recovered** metric, deliberately the
largest, most visually dominant number on the page) and a collapsible
`PolicyConfigPanel`.

### Demo scenarios

The `ScenarioPicker` component ships four scenarios that exercise the
architecture's key branches:

- **A — Successful recovery**: temporary failure, strong payment history →
  high-value retry recommended and allowed.
- **B — Customer opted out**: guardrails block any contact action
  regardless of transaction value — the single most important safety
  scenario in the spec.
- **C — Retry/contact limit reached**: further automated contact is
  blocked once the policy's attempt limit is hit.
- **D — Permanent failure**: invalid payment details → no aggressive
  retry; a safe alternative action is chosen instead.

### Batch evaluation — real numbers

Run `GET /api/v1/agent/evaluation/report?n=5000&seed=42` (or open the AI
Agent tab, which calls it automatically). A representative run on 5,000
synthetic cases (seed 42) completed in well under half a second:

```
total_cases:                5000
total_revenue_at_risk:      ₹137,501,955.08
eligible_cases:             4357
recovery_attempts:          2316
successful_recoveries:      954
recovery_rate:              41.19%
revenue_recovered:          ₹6,941,596.11
revenue_recovery_percentage: 5.05%
blocked_actions:            1274
customer_opt_outs:          202
stopped_cases:              2674
average_recovery_value:     ₹7,276.31
```

Every number above came from actually running `evaluate_agent()` against
the Phase 13 generator's output during this session — none of it is
invented.

### Testing

New Phase 15 test files, mirroring the same unittest style as every
earlier phase:

```
tests/test_phase15_agent.py           # AI agent: structured result, confidence bounds,
                                       # evidence, deterministic provider, no network
tests/test_phase15_guardrails.py      # 9 stopping rules + policy-overrides-agent invariant
tests/test_phase15_explainability.py  # traceable reasons, no fabrication
tests/test_phase15_audit.py           # every stage produces an audit event
tests/test_phase15_evaluation.py      # metrics are mathematically correct, deterministic
tests/test_phase15_pipeline.py        # full orchestrator + demo scenarios A-D
tests/test_phase15_api.py             # /api/v1/agent/* endpoints, backward compatibility
```

```bash
python3 -m unittest discover -s tests -v   # full suite, 390 tests
```

Frontend: `frontend/src/utils/format.test.ts` covers the new
`guardrailTone`/`actionLabel`/`formatPercent` helpers alongside the
existing ones (`npm test` inside `frontend/`).

### Security

CORS was widened from two hardcoded origins to a loopback-only regex
(`http://(localhost|127.0.0.1):<any port>`) so a local dev server can bind
to an uncommon port without needing the backend edited — still never a
wildcard. See `SECURITY.md`'s "Phase 15 additions" section for the full
audit.

### Limitations (honest, not hidden)

- The `DeterministicReasoningProvider`'s "reasoning" is a template filled
  in from real data, not a call to an actual language model — by design,
  so the demo works completely offline with no API key. The
  `ReasoningProvider` interface exists so a real LLM could be added later
  without touching any other Phase 15 module.
- The in-memory `AGENT_RECENT_RESULTS` store (used by the `GET
  /agent/{transaction_id}*` endpoints) has the same process-lifetime-only
  tradeoff as Phase 7's `store.py` — results don't survive a server
  restart.
- Precision/Recall/F1/ROC-AUC are not reported, for the reason explained
  above — this is a deliberate scope decision, not a missing feature.

## Next phase

Phase 15 is the last planned phase in this build sequence. Possible future
work (not started): a real persistence layer for the in-memory result store,
an actual LLM-backed `ReasoningProvider` behind the existing interface,
additional dashboard pages (Recovery Queue, Case Details), real
payment-gateway sandbox integration.
