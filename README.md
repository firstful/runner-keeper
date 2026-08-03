# runner-keeper

Wakes the gitea-runner when CI runs queue; sleeps it after 30 min idle.

- **CronJob** `runner-keeper` (ns `gitea-runner`, every 60s): polls the Gitea
  Actions API for `queued`/`in_progress` runs → scale `deploy/runner` to 1
  (the wake MUST be external — a workflow can't run on a scaled-to-0 runner).
  Sleeps it to 0 after `IDLE_MINUTES` (default 30) of no activity, tracked via
  the `runner-keeper/last-activity` annotation (Flux driftDetection.ignore in
  `clusters/sutliffserver/infra.yaml`).
- Token secret `runner-keeper-gitea` (imperative, not in git).
- Gotchas: Gitea statuses are `queued/in_progress/completed` (NOT `running`);
  runs API returns `{"workflow_runs":[...]}`; busybox `date` can't parse ISO
  `T`/`Z` — normalize first.

Image built by CI (this workflow) on push to main → `192.168.1.2:3000/reeds/runner-keeper:latest` + `:<sha8>`. Bump the tag in sutliff-cluster after a source change.

NOTE: keeper builds via the runner it wakes — if the keeper image is broken, the
runner sleeps forever. Recovery: manually scale the runner deployment to 1.
