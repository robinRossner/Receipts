"""E2E test hook: finish the receipts' queued extractions with the test suite's scripted fake provider.

Run from the FitnessBuddy repo's `backend/` (RECEIPTS_BACKEND_DIR) against the SAME environment as the e2e server (temp RECEIPTS_DATABASE_URL, no Claude
credentials), with the server's worker thread disabled (`RECEIPTS_WORKER_ENABLED=false`):

    uv run python "<Receipts App>/Tests/e2e/seed_extractions.py"

It uses `worker.run_next` with `tests.receipts_helpers.FakeProvider`, the same hook the backend's own tests use,
so no Claude call is ever made. Prints how many jobs it finished.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))  # backend/ (so `apps` and `tests` import)

from apps.receipts import worker  # noqa: E402
from apps.receipts.db.session import get_session_factory  # noqa: E402
from tests.receipts_helpers import FakeProvider, receipt_json  # noqa: E402

factory = get_session_factory()
provider = FakeProvider([receipt_json([("Bio Eier 10er", 1, 2.49), ("Milch", 2, 1.19)], store="Edeka")])
done = 0
while worker.run_next(factory, provider):
    done += 1
print(done)
