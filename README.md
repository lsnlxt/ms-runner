# ms-runner

Public mirror of `queue/test/tools/ms-worker.sh` from the private repository
`lsnlxt/lidar-ai-bus`, plus a bootstrap script and a public queue fixture.

## Why this exists

ModelScope Notebooks cannot reach github.com over the git protocol (connections
time out). The `codeload` endpoint does work, but it returns 404 for private
repositories unless the request carries a valid token.

This repository is public so the notebook can download the worker script with no
credentials at all. Getting the script in and letting the script run are two
separate concerns: the runtime still needs its own `GH_TOKEN` to reach the
private queue.

## Quick start

On a fresh notebook instance:

```
curl -sL -o /tmp/run-ms.sh "https://codeload.github.com/lsnlxt/ms-runner/tar.gz/refs/heads/main" && \
tar -xzf /tmp/run-ms.sh -C /tmp --strip-components=1 ms-runner-main/run-ms.sh && \
bash /tmp/run-ms.sh
```

Expected result: one dry-run round against the public fixture, ending with the
worker's `EXIT=0`. No credentials are required for this.

## Files

| File | Purpose |
|---|---|
| `ms-worker.sh` | The worker itself. Line-for-line copy of the private source. |
| `run-ms.sh` | Fetch + syntax check + one dry-run round. |
| `queue/test/in/job-public-0001/` | Synthetic job used by the dry-run. It points at `octocat/Hello-World` on purpose: the real queue points at private repos and needs a token. |

## Real runs

Export before invoking, never write to disk:

```
export GH_TOKEN=...            # read access to the private queue repo
export OPENROUTER_API_KEY=...  # used by the codex execution step
```

Then run `ms-worker.sh` against the private queue by overriding the defaults:

```
BUS_OWNER=lsnlxt BUS_REPO=lidar-ai-bus QUEUE_BRANCH=queue/test \
  /tmp/ms-worker.sh --project test --once
```

## Operational notes

- An invalid `Authorization` header makes codeload return **404 even for public
  repos**, so a bad token looks exactly like a missing branch. The worker now
  retries anonymously before declaring failure.
- The circuit breaker counter lives at `${WORK_ROOT}/guard/consecutive_failures`
  and accumulates across processes. `run-ms.sh` resets it.
- `--once` exits `0` when the round completes, regardless of the job's own
  status. Job outcome is in `result.json` (`status`, `exit_code`).

## No secrets

This repository contains no credentials. The worker reads `GH_TOKEN` and
`OPENROUTER_API_KEY` from the environment at runtime and redacts them from its
own log output.
