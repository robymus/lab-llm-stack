"""Shared pytest fixtures for the agent app's tests.

The tool module reads `MOCK_SERVICES_URL` at import time to build its shared
httpx client. We seed it here, before any test imports `tools`, so the URL
is deterministic and matches what respx intercepts.
"""

import os

# Set before importing tools — must happen at module level, not inside a
# fixture, because `tools` is imported once at collection time.
os.environ.setdefault("MOCK_SERVICES_URL", "http://mock-services.test")
