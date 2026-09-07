# RecoverX backend. This build is intentionally simple: the current
# vertical-slice architecture has no database dependency (SQLite in Phase 1
# is a standalone, tested module — never wired into the API layer) and no
# LLM/external API dependency (diagnosis and decisions are fully
# deterministic, rule-based). One Python image, no multi-service compose
# complexity needed for the backend alone.
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY recoverx/ ./recoverx/

# Never bake secrets into the image. This backend currently reads no
# environment variables at all (see recoverx/api/ — no os.environ/getenv
# calls anywhere), but ENV/--env-file is the correct place for any added
# later, never a COPY'd .env file.

EXPOSE 8000

# No --reload in the container image: that's a local-dev convenience only.
CMD ["uvicorn", "recoverx.api.app:app", "--host", "0.0.0.0", "--port", "8000"]
