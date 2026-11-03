# ms-runner

Public mirror of `queue/test/tools/ms-worker.sh` from the private repository
`lsnlxt/lidar-ai-bus`.

## Why this exists

ModelScope Notebooks cannot reach github.com over the git protocol (connections
time out). The `codeload` endpoint does work, but it returns 404 for private
repositories unless the request carries a valid token.

This repository is public so the notebook can download the worker script through
`codeload` with no credentials at all. Getting the script in and letting the
script run are two separate concerns: the runtime still needs its own
`GH_TOKEN` to reach the private queue.

## Fetch

```
curl -sL -o /tmp/ms-worker.sh "https://codeload.github.com/lsnlxt/ms-runner/tar.gz/refs/heads/main"
```

The tarball extracts to `ms-runner-main/`, so the file lands at
`ms-runner-main/ms-worker.sh`.

## No secrets

This repository contains no credentials. The script reads `GH_TOKEN` and
`OPENROUTER_API_KEY` from the environment at runtime and redacts them from its
own log output.
