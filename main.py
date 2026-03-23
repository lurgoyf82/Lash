"""ASGI entrypoint for the default LASH FastAPI gateway."""

from fastapi import FastAPI

app = FastAPI(title="LASH Gateway")


@app.get("/health", tags=["system"])
def health() -> dict[str, str]:
    """Return a lightweight readiness payload for local health checks."""
    return {"status": "ok"}
