# RecoverX — Demo Guide

## Quickstart (local, without Docker)

```bash
# Backend
cd recoverx
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn recoverx.api.app:app --reload
# → http://127.0.0.1:8000/docs

# Frontend (separate terminal)
cd frontend
npm install
npm run dev
# → http://localhost:5173
```

## Quickstart (Docker)

```bash
docker compose up --build
```
Backend: `http://localhost:8000/docs`. Frontend: `http://localhost:5173`.

⚠️ **Docker itself was not available in the sandbox this project was built
in** — the `Dockerfile`s and `docker-compose.yml` are written and
YAML-syntax-checked, but the actual build/run is **UNVERIFIED — REQUIRES
LOCAL EXECUTION**. Please confirm `docker compose up --build` actually works
before relying on it for a live demo.

## Suggested demo flow (5 endpoints, ~3 minutes)

1. **Health check** — `GET /api/v1/health` → confirms the service is up.
2. **A normal recovery** — `POST /api/v1/recovery/analyze` with a ₹4,999
   temporary-bank-failure transaction and a strong-history customer → walk
   through Risk → Diagnosis → Decision → Policy → Simulation in the response
   (or in the frontend's pipeline rail).
3. **Safety in action** — repeat with `amount: 80000` → show
   `policy.decision: "ESCALATE"` and that no automated action executes.
4. **What-if comparison** — `POST /api/v1/recovery/what-if` on the same
   transaction → show the ranked strategy table (real output, e.g. from this
   build: `RETRY_PAYMENT` net ₹4,144 > `WAIT_AND_RETRY` ₹3,894 >
   `SEND_PAYMENT_LINK` ₹3,134 > `ESCALATE_TO_HUMAN` ₹1,850).
5. **Evaluation at scale** — `GET /api/v1/evaluation/report?n=5000` → real
   headline numbers (below).

## Real evaluation numbers (5,000 synthetic transactions, seed=42)

Actually generated and run — not fabricated:

| Metric | Value |
|---|---|
| Total transactions evaluated | 5,000 |
| Total revenue at risk | ₹137,501,955.08 |
| Naive baseline ("always retry once") net recovery | ₹40,841,290.62 |
| RecoverX net recovery | ₹6,647,319.15 |

**RecoverX's raw number is lower than the baseline's — and that's the
point, not a flaw.** Breaking down RecoverX's outcomes by policy decision:

| Policy decision | Cases | % | Revenue at risk | Simulated recovery |
|---|---|---|---|---|
| ALLOW | 2,764 | 55.3% | ₹14,930,907 | ₹6,941,596 |
| BLOCK | 1,089 | 21.8% | ₹34,322,426 | ₹0 |
| ESCALATE | 942 | 18.8% | ₹86,752,815 | ₹0 |
| MODIFY | 205 | 4.1% | ₹1,495,807 | ₹0 |

**The honest story:** 40.6% of at-risk revenue (₹121M) sits in cases
RecoverX correctly escalated or blocked — high-value transactions requiring
human approval, retry-limits reached, opted-out customers. The naive
baseline blindly retries all of it and gets simulated credit for some
successes; RecoverX defers those judgment calls to a human rather than
guessing. This is a genuine safety/return tradeoff, presented transparently
— see `README.md`'s Phase 13 section and
`recoverx/evaluation/engine.py`'s module docstring for the full explanation.

## 5-minute pitch structure

**0:00–0:30 — Problem.** Merchants lose revenue to failed payments and
checkout abandonment. Blindly retrying everything is unsafe (contacts
opted-out customers, retries after limits, no human review for high-value
cases) — but doing nothing loses real money.

**0:30–1:00 — Solution.** RecoverX: Detect → Diagnose → Decide → Policy →
Simulate. A safety-gated recovery pipeline where every automated action
passes a policy check before anything happens.

**1:00–2:30 — Live demo.** Run the 5 endpoints above live.

**2:30–3:30 — Evaluation + safety tradeoff.** Present the table above
honestly — this is the strongest, most credible part of the pitch precisely
*because* it's not a simple "we win" number. It shows the system reasoning
about risk, not just chasing revenue.

**3:30–4:15 — Safety architecture.** Policy Engine as the one hard gate
between recommendation and execution; human-in-the-loop approval for
escalated cases; every simulated action explicitly labeled as simulated.

**4:15–5:00 — What's next.** Persistence layer, LLM-assisted diagnosis for
ambiguous cases, checkout-abandonment dashboard pages, real payment-gateway
sandbox integration.

## Phase 15 demo flow (AI Agent tab, ~2 minutes)

Open the frontend's **"AI Agent (Phase 15)"** tab (now the default tab) and
click through the four `ScenarioPicker` buttons in order:

1. **A — Successful recovery** — high-value temporary failure, strong
   customer history. Watch the pipeline rail go Detect → AI Reason →
   Guardrails (**ALLOWED**) → Simulate (**SUCCESS**). Expand the "AI
   Diagnosis & Reasoning" panel to see the generated reasoning narrative
   and alternative actions considered; expand "Why did the agent choose
   this?" to see the same decision explained as a checklist.
2. **B — Customer opted out** — same shape of failure, but the customer
   opted out of contact. The Guardrails panel shows **BLOCKED**, `STOP
   REASON: CUSTOMER_OPTED_OUT`, and the simulation shows nothing was
   executed. This is the single most important safety scenario in the demo
   — the AI's raw recommendation never reaches the simulator.
3. **C — Retry/contact limit reached** — same idea, blocked for a
   different, equally deterministic reason.
4. **D — Permanent failure** — invalid payment details; no aggressive
   retry is attempted, a safe alternative is chosen instead.

Scroll down past any result to the always-visible **RecoverX Performance**
dashboard — the batch evaluation's ₹ Revenue Recovered number, computed
live from the real Phase 15 pipeline on demand (not cached, not invented).

## What this demo does NOT claim

- No real money moves. Every recovery figure is `simulated_*`.
- No real customer was contacted at any point in building or testing this.
- The evaluation dataset is synthetic (Phase 13), not real merchant data.
- The AI agent's "reasoning" is generated by a deterministic, offline
  template (see `recoverx/agent/provider.py`), not an actual call to a
  language model — no API key is required, and this project never claims
  otherwise.
