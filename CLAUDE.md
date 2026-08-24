# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`tap-github` is a [Singer](https://www.singer.io/) tap for the GitHub API, built with the [Meltano Singer SDK](https://sdk.meltano.com/). It extracts data from GitHub's REST and GraphQL APIs and emits Singer-format records for downstream loaders.

### Branch model (xflow fork)

This is xflow's fork of `MeltanoLabs/tap-github`. Two long-lived branches:

- **`main`** — a *pristine read-only mirror* of `MeltanoLabs/tap-github` `main`. Never commit xflow work here. Re-sync with `git fetch upstream && git checkout main && git merge --ff-only upstream/main` (the `upstream` remote points at `github.com/MeltanoLabs/tap-github`).
- **`xflow_dev`** — `main` plus xflow's enhancements. This is the working branch.

To re-baseline on a newer upstream: create `xflow_dev` fresh from the updated `main`, then replay the xflow commits onto a `tmp/xflow_r1_merge` staging branch (resolve conflicts there), and fast-forward `xflow_dev` to it. The older `develop` / `task/meltano_4.x` branches shadowed MeltanoLabs' own `develop` and are no longer used.

**xflow enhancements layered on top of upstream** (all in `authenticator.py` / `client.py` / `repository_streams.py`):

- **Rate-limit wait + retry**: when all tokens are exhausted, `get_next_auth_token()` sleeps until the earliest token reset instead of erroring; `client.py`'s `_send_request_with_backoff` adds `backoff` retries.
- **`PullRequestFilesStream`** (`pulls/{pull_number}/files`) and `pull_number` on `ReviewCommentsStream` (parsed from `pull_request_url`).

OAuth tokens are not handled specially — GitHub accepts them with the same `token`/`Bearer` header as PATs and this fork doesn't refresh them, so pass them via `auth_token` / `additional_auth_tokens` like any other token.

## Commands

The project uses **uv** (not poetry) and a **hatchling/hatch-vcs** build backend. Tests live in the top-level `tests/` directory.

```bash
uv sync                              # set up dev environment
uv run pytest                        # run the full test suite
uv run pytest tests/test_core.py::test_name   # run a single test
uv run pytest -m repo_list           # markers: noconfig, repo_list, username_list
uv run tap-github --help             # exercise the CLI directly
uv run tap-github --config config.json --discover > catalog.json
uv run ruff check tap_github/        # lint  (uv run ruff format — format)
uv run mypy tap_github               # type check
pre-commit run --all-files           # ruff lint + ruff-format + file hygiene
uv run tox                           # mypy + tests across py3.12–3.13 (tox config is in pyproject.toml)
```

Tests require GitHub auth tokens via env vars (any `GITHUB_TOKEN*`) or `.secrets/`. Without a token, the API rate limit is very low and tests will fail on 403s. `requests-cache` (dev dep) caches API responses to speed up repeated test runs. Tests marked `noconfig` run without config.

### The live suite is a local gate, not a CI one (xflow)

CI runs only `type` (mypy + ty) and the `noconfig` discovery test. A cold-cache run of the **full** suite costs ~1600 GitHub API requests, but `secrets.GITHUB_TOKEN` is capped at 1,000/hour per repository, so CI cannot finish it — it exhausts the quota and then sleeps in the workflow's retry step. Run it locally before tagging a release:

```bash
GITHUB_TOKEN=<a PAT with 5,000/hr>  uv run pytest       # ~1600 requests, ~70 min
```

Notes on cost and targets, all measured:

- Live-test targets are env-overridable: `TAP_GITHUB_TEST_REPOS`, `_ORGS`, `_USERNAMES`, `_USER_IDS` (comma-separated; upstream's values are the fallbacks). `.env` points them at this repo.
- Cost is dominated by the nine child streams that fetch **per parent record** (`sub_issues`, `issue_dependencies_*`, `issue_field_values`, `pull_request_{commits,diffs,files}`, `reviews`, `review_comment_reactions`), so it scales with issue/PR count, not date range. Targeting a small repo cut a run from ~5000 to ~1600 requests.
- `start_date` is already *today* in the fixtures, and 33 of 52 repo-mode streams have no replication key while 5 more set `use_fake_since_parameter` (paging everything and filtering client-side). Widening it only adds cost.
- `tests/conftest.py` offers `TAP_GITHUB_TEST_PER_PAGE` / `TAP_GITHUB_TEST_MAX_RESULTS` pagination caps, but they save only ~6% and break `test_get_a_user_in_user_usernames_mode`, which asserts >150 records on purpose. Not a useful lever.
- Extra PATs from the *same* account add no headroom: GitHub's primary rate limit is per user, not per token.
- Three tests dominate (`test_last_state_message_is_valid` and the two `test_get_a_repository_in_repo_list_mode` cases). They are pinned to `repo_list_2` — MeltanoLabs repos with deliberate case typos, validated against hard-coded repo IDs — so the target env vars do not affect them.

## Architecture

**Config-mode → stream selection.** A run must specify exactly one "path" config key. `tap.py`'s `discover_streams()` reads the config, then `streams.py`'s `Streams` enum maps each valid query key to the set of stream classes it enables:

- **Repository modes**: `repositories`, `organizations`, `searches` → `REPOSITORY` streams
- **User modes**: `user_usernames`, `user_ids` → `USERS` streams
- **Org mode**: `organizations` → also enables `ORGANIZATIONS` streams

If you add a stream, you must register its class in the appropriate `Streams` enum entry, or it will never be discovered.

**Stream base classes** live in `client.py`:

- `GitHubRestStream` — base for all REST streams. Handles page/cursor pagination (`use_cursor_pagination`), the `since` parameter and the `use_fake_since_parameter` workaround for endpoints missing it, `MAX_PER_PAGE`/`MAX_RESULTS_LIMIT`, `tolerated_http_errors`, and rate-limit-aware request sending with `backoff` retries in `_send_request_with_backoff`.
- `GitHubGraphqlStream` — GraphQL streams (e.g. stargazers).
- `GitHubDiffStream` — streams that fetch `.diff` output.

**Stream definitions** are grouped by domain, one large module each:

- `repository_streams.py` (~3900 lines) — the bulk of streams (issues, PRs, commits, releases, traffic, workflows, …)
- `organization_streams.py` — orgs, teams, projects, members
- `user_streams.py` — users, starred, contributed-to

**Parent-child streams** are the core pattern. Most streams declare `parent_stream_type = RepositoryStream` (or similar) and `state_partitioning_keys = ["repo", "org"]`. The parent's `get_child_context()` passes identifiers down; the child's `partitions` / `path` consume them. When adding a stream that depends on repo/org/PR/etc. context, follow this pattern rather than re-fetching parents. `skip_parent_streams` config lets parents be queried-but-not-emitted when only children are selected.

**Authentication** (`authenticator.py`) supports a pool of credentials that rotate on rate-limit exhaustion. The authenticator is **decoupled from the stream** — `GitHubTokenAuthenticator.__init__` takes explicit kwargs, built from stream config in the `from_stream` classmethod (add new auth config there, not via `self.config`). `prepare_tokens()` returns an **org-keyed dict** `dict[str | None, list[TokenManager]]`: app keys can be org-scoped, while personal tokens are org-agnostic and stored under the `None` key. `get_next_auth_token()` selects candidates by priority (current-org pool → `None` pool → other orgs) since installation tokens are org-scoped. `TokenManager` subclasses: `PersonalTokenManager` (PATs — and OAuth tokens — from `auth_token` / `additional_auth_tokens` / any `GITHUB_TOKEN*` env var) and `AppTokenManager` (GitHub Apps — mint short-lived JWTs, refresh before `expiry_time_buffer`). Each manager tracks its own `rate_limit_remaining`; the authenticator honors `rate_limit_buffer` and, when everything is exhausted, waits until the earliest reset (xflow).

**Scraping** (`scraping.py`) handles data GitHub exposes only in HTML (not the API), e.g. dependents / used-by counts, via BeautifulSoup. Used by `ExtraMetricsStream`, `DependentsStream`.

## Conventions

- Ruff governs lint + format (config in `pyproject.toml`, broad rule set incl. `ANN` annotations — relaxed for tests). Run `pre-commit` before committing.
- Target Python 3.12 (`requires-python = ">=3.12"`; CI tests 3.12 and 3.13, and `.python-version` pins the dev default to 3.12). Use PEP 604 (`X | None`, not `Optional[X]`). Type-only imports go under `if TYPE_CHECKING:` — but keep runtime-used imports (e.g. `requests`) at module level. `from __future__ import annotations` is no longer required for these, but the existing modules all carry it — keep it when editing them for consistency.
- Schemas are declared inline with the SDK's `singer_sdk.typing as th` helpers; reusable object fragments live in `schema_objects.py`.
- `traffic_*` streams require **write** access to the repo (GitHub API constraint), so they are not always usable.
