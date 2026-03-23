"""Default Celery application and example task for LASH deployments."""

import os

from celery import Celery


def create_celery_app() -> Celery:
    """Create the Celery application using deploy-time broker configuration."""
    broker_url = os.getenv("CELERY_BROKER_URL", "redis://localhost:6379/0")
    backend_url = os.getenv("CELERY_RESULT_BACKEND", broker_url)
    app = Celery("lash", broker=broker_url, backend=backend_url)
    app.conf.task_default_queue = "default"
    return app


celery_app = create_celery_app()


@celery_app.task(name="lash.ping")
def ping() -> str:
    """Return a deterministic heartbeat string for worker smoke testing."""
    return "pong"
