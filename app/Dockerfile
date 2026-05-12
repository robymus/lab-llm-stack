# =============================================================================
#  Agent app container
# -----------------------------------------------------------------------------
#  Same shape as mock-services: slim Python base, requirements layer
#  before app code for cache friendliness.
# =============================================================================

FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Some traceloop dependencies (tiktoken, etc.) need a C compiler at install
# time on some Python wheel-less arches. python:3.11-slim usually has wheels
# for x86_64/arm64 but not always; install build-essential just in case.
# Apt steps are pinned to no-recommends and cleaned up to keep the image lean.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install -r requirements.txt

# Remove the build chain after pip install — saves ~250 MB in the final image.
RUN apt-get purge -y build-essential \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

COPY app.py agent.py tools.py ./

EXPOSE 8501

# --server.headless=true: don't try to open a browser inside the container.
# --browser.gatherUsageStats=false: turn off Streamlit's telemetry.
CMD ["streamlit", "run", "app.py", \
     "--server.address=0.0.0.0", \
     "--server.port=8501", \
     "--server.headless=true", \
     "--browser.gatherUsageStats=false"]
