# =============================================================================
#  mock-services container
# -----------------------------------------------------------------------------
#  Slim Python base; one binary (uvicorn) and one file (main.py). Layer
#  caching: requirements first, then app code, so iterating on main.py
#  doesn't reinstall pip deps.
# =============================================================================

FROM python:3.11-slim

# Set predictable Python behaviour: no .pyc, unbuffered logs (so docker
# compose logs sees output line by line), no pip version-check noise.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY main.py .

EXPOSE 9000

# --proxy-headers is harmless here (no proxy yet) but kept in case we
# ever put nginx in front. --no-server-header trims the response by
# one HTTP header.
CMD ["uvicorn", "main:app", "--host=0.0.0.0", "--port=9000", "--proxy-headers", "--no-server-header"]
