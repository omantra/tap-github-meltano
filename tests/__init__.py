"""Test suite for tap-github."""

from __future__ import annotations

from typing import TYPE_CHECKING

import requests_cache

if TYPE_CHECKING:
    import requests


def _is_cacheable(response: requests.Response) -> bool:
    """Refuse to cache GraphQL responses that carry an `errors` payload.

    GitHub answers a failed GraphQL query with HTTP 200 and the failure in the
    body, so `requests-cache` would happily store it. A one-off server-side
    error ("Something went wrong while executing your query...") then replays
    from disk for the whole 24h expiry window, turning a flake into a
    deterministic test failure that no amount of re-running clears -- and CI
    can pick one up through its cached sqlite file too.

    Errors are never worth persisting, so none are stored. The only cost is
    that the deliberate "does this repo exist" probe in `repo_list_2` re-issues
    its query each run, which is a single request.
    """
    if "/graphql" not in str(response.url):
        return True

    try:
        body = response.json()
    except ValueError:  # not JSON (e.g. the `.diff` streams)
        return True

    return not (isinstance(body, dict) and body.get("errors"))


# Setup caching for all api calls done through `requests` in order to limit
# rate limiting problems with github.
# Use the sqlite backend as it's the default option and seems to be best supported.
# To clear the cache, just delete the sqlite db file at api_calls_tests_cache.sqlite
# in the root of this repository
requests_cache.install_cache(
    ".cache/api_calls_tests_cache",
    backend="sqlite",
    # make sure that API keys don't end up being cached
    # Also ignore user-agent so that various versions of request
    # can share the cache
    ignored_parameters=["Authorization", "User-Agent", "If-modified-since"],
    # tell requests_cache to check headers for the above parameter
    match_headers=True,
    # expire the cache after 24h (86400 seconds)
    expire_after=24 * 60 * 60,
    # make sure graphql calls get cached as well
    allowable_methods=["GET", "POST"],
    # ...but never cache a GraphQL error, which GitHub returns with HTTP 200
    filter_fn=_is_cacheable,
)
