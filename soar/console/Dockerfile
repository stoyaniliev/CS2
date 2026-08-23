# Multi-stage so the runtime image carries no build tooling.
FROM public.ecr.aws/docker/library/python:3.12-slim AS build

WORKDIR /install
RUN pip install --no-cache-dir --target=/install/deps boto3==1.35.0

FROM public.ecr.aws/docker/library/python:3.12-slim

# Runs unprivileged. A dashboard has no reason to be root, and the base image
# defaults to it.
RUN useradd --create-home --uid 10001 soar

WORKDIR /app
COPY --from=build /install/deps /app/deps
COPY app.py /app/app.py

ENV PYTHONPATH=/app/deps \
    PYTHONUNBUFFERED=1 \
    PORT=8080

USER soar
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/healthz')"

CMD ["python3", "/app/app.py"]

# pipeline verification run
