FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# dependencies first, so this layer is cached until requirements.txt changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py wsgi.py ./

# the running version, shown at "/" and in metrics (set by CI to the git sha)
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

# never run as root inside the container
RUN useradd --system --uid 10001 appuser
USER appuser

EXPOSE 8000

# python:slim has no curl, so the check uses the standard library
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"

# One worker + threads on purpose: Prometheus metrics live in process memory,
# so one process per container keeps them correct. We scale with replicas instead.
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "1", "--threads", "8", \
     "--timeout", "30", "--graceful-timeout", "20", "--error-logfile", "-", "wsgi:app"]
