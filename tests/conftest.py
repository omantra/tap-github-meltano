from __future__ import annotations

import os

import pytest

from tap_github.client import GitHubRestStream

pytest_plugins = "pytester"


@pytest.fixture(autouse=True)
def _cap_rest_pagination(monkeypatch):
    """Optionally cap REST pagination to keep a full live run cheap.

    The suite's cost is dominated by the ~9 child streams that issue one request
    per parent record, so a busy repo can consume the whole 5000/hour quota.
    Setting a small page size together with a small result cap still exercises
    the paginator over several pages -- which is what the pagination tests are
    actually asserting -- while spending a handful of calls per stream.

    Both are opt-in via the environment so the default run keeps upstream's
    full-extraction behaviour:

        TAP_GITHUB_TEST_PER_PAGE=5 TAP_GITHUB_TEST_MAX_RESULTS=15 uv run pytest

    Note that capping can break tests asserting exact record counts, so keep the
    cap comfortably above any count the suite expects.
    """
    per_page = os.environ.get("TAP_GITHUB_TEST_PER_PAGE")
    max_results = os.environ.get("TAP_GITHUB_TEST_MAX_RESULTS")

    if per_page:
        monkeypatch.setattr(GitHubRestStream, "MAX_PER_PAGE", int(per_page))
    if max_results:
        monkeypatch.setattr(GitHubRestStream, "MAX_RESULTS_LIMIT", int(max_results))
