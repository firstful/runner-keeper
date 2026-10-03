#!/bin/bash
# runner-keeper: wake the gitea-runner when CI runs queue, sleep it after idle.
# External wake is required (a workflow can't run on a runner scaled to 0).
set -u

GITEA_URL="${GITEA_URL:-http://192.168.1.2:3000}"
TOKEN="$(cat /var/run/secrets/gitea-token/token 2>/dev/null || echo "${GITEA_TOKEN:-}")"
NS="${NAMESPACE:-gitea-runner}"
DEPLOY="${DEPLOY_NAME:-runner}"
IDLE_MIN="${IDLE_MINUTES:-30}"
ANNOT="runner-keeper/last-activity"

KUBE_TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
KUBE_CA="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
KUBE="https://kubernetes.default.svc"
HDR_AUTH="Authorization: Bearer $KUBE_TOKEN"
DEP_URL="$KUBE/apis/apps/v1/namespaces/$NS/deployments/$DEPLOY"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

get_deploy() {
  curl -sf --cacert "$KUBE_CA" -H "$HDR_AUTH" "$DEP_URL"
}

patch_deploy() {
  curl -sf --cacert "$KUBE_CA" -X PATCH -H "$HDR_AUTH" \
    -H "Content-Type: application/strategic-merge-patch+json" \
    -d "$1" "$DEP_URL" >/dev/null
}

[ -z "$TOKEN" ] && { log "ERROR: no GITEA token"; exit 0; }

# 1. Find any queued/running Actions runs across all reeds repos
ACTIVE=0
REPO_COUNT=0
# Gitea caps a search page at 50 no matter what limit you ask for, so
# limit=100 silently returned only 50 repos — alphabetically ending at
# "smoke-*". reeds/talaria was invisible, its queued run never woke the
# runner, and CI sat queued forever. Page until we stop getting results.
# 2026-10-03.
REPOS=""
PAGE=1
while :; do
  PAGE_REPOS=$(curl -sf -H "Authorization: token $TOKEN" \
    "$GITEA_URL/api/v1/repos/search?limit=50&page=$PAGE" \
    | jq -r '.data[]?.full_name' 2>/dev/null)
  [ -n "$PAGE_REPOS" ] || break
  REPOS="$REPOS $PAGE_REPOS"
  [ "$(echo "$PAGE_REPOS" | wc -l)" -lt 50 ] && break
  PAGE=$((PAGE+1))
  [ "$PAGE" -gt 10 ] && break
done
[ -n "$REPOS" ] || { log "ERROR: repo search returned nothing"; exit 0; }
for r in $REPOS; do
  REPO_COUNT=$((REPO_COUNT+1))
  runs=$(curl -sf -H "Authorization: token $TOKEN" "$GITEA_URL/api/v1/repos/$r/actions/runs?limit=5" 2>/dev/null)
  [ -z "$runs" ] && continue
  # Gitea run statuses: queued -> in_progress -> completed (NOT "running").
  # API shape: {"workflow_runs": [...], "total_count": N}
  if echo "$runs" | jq -e '[.workflow_runs[]? | select(.status=="queued" or .status=="in_progress")] | length > 0' >/dev/null 2>&1; then
    ACTIVE=1
  fi
done

# 2. Read current state from the Deployment (replicas + idle annotation)
D="$(get_deploy)"
[ -z "$D" ] && { log "ERROR: cannot read deployment"; exit 0; }
CUR=$(echo "$D" | jq -r '.spec.replicas // 0')
LAST=$(echo "$D" | jq -r ".metadata.annotations[\"$ANNOT\"] // empty" 2>/dev/null)

now_epoch=$(date +%s)
idle_age="unknown"
if [ -n "$LAST" ]; then
  # busybox date can't parse ISO "T" separator / "Z" suffix — normalize first
  last_epoch=$(date -u -d "$(echo "$LAST" | sed 's/T/ /; s/Z//')" +%s 2>/dev/null || echo 0)
  [ "$last_epoch" -gt 0 ] && idle_age=$(( (now_epoch - last_epoch) / 60 ))
fi

log "repos=$REPO_COUNT active=$ACTIVE replicas=$CUR idle_age=${idle_age}m (threshold ${IDLE_MIN}m)"

if [ "$ACTIVE" = "1" ]; then
  # 3a. Wake / stay up + refresh idle clock
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ "$CUR" -lt 1 ]; then
    patch_deploy "{\"metadata\":{\"annotations\":{\"$ANNOT\":\"$now_iso\"}},\"spec\":{\"replicas\":1}}" \
      && log "WAKE: scaled $DEPLOY to 1 (queued runs)" || log "ERROR: wake patch failed"
  else
    patch_deploy "{\"metadata\":{\"annotations\":{\"$ANNOT\":\"$now_iso\"}}}" \
      && log "active — refreshed idle clock" || log "ERROR: annotation patch failed"
  fi
else
  # 3b. Sleep after IDLE_MIN with no activity
  if [ -z "$LAST" ]; then
    log "no activity history yet — leaving runner as-is"
  elif [ "$idle_age" != "unknown" ] && [ "$idle_age" -ge "$IDLE_MIN" ] && [ "$CUR" -gt 0 ]; then
    patch_deploy '{"spec":{"replicas":0}}' && log "SLEEP: scaled $DEPLOY to 0 (idle ${idle_age}m)" \
      || log "ERROR: sleep patch failed"
  else
    log "idle ${idle_age}m (threshold ${IDLE_MIN}m), replicas=$CUR — runner stays"
  fi
fi
