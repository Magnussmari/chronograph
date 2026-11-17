#!/usr/bin/env bash
# deploy-edge.sh — ship Chronograph to the sovereign edge (smarason-edge-hel1).
#
#   timeline.sumarhus.com -> Caddy vhost -> 127.0.0.1:3001 -> container `timeline-app`
#   compose file: /opt/timeline/docker-compose.yml   (image tag is read from it)
#   source clone: /opt/timeline-src  (reset to origin/main)
#
# SSH goes over the tailnet via the `smarason-edge-hel1` alias in ~/.ssh/config.
# (Until 2026-11-17 this script opened a temporary hcloud firewall rule for the
# public egress IP; the tailnet path made that unnecessary, and the RW token now
# lives in the macOS keychain rather than the vault note the script parsed.)
# next build needs ~4G RAM on a cx23, so a temp swapfile is added and removed.
# The previous image is kept as <tag>-prev for a one-command rollback:
#   ssh smarason-edge-hel1 'docker tag timeline-edge:v12-prev timeline-edge:v12 && cd /opt/timeline && docker compose up -d --force-recreate'
#
# Usage:  scripts/deploy-edge.sh [--dry-run]
set -euo pipefail

SERVER="smarason-edge-hel1"
DRY_RUN="${1:-}"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# --- preflight: never deploy an unbuilt, dirty or unpushed tree ----------------
log "preflight"
ROOT="$(dirname "$0")/.."
git -C "$ROOT" diff --quiet || { echo "working tree dirty — commit first"; exit 1; }
git -C "$ROOT" fetch --quiet origin main
LOCAL_SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
REMOTE_SHA="$(git -C "$ROOT" rev-parse --short origin/main)"
[[ "$LOCAL_SHA" == "$REMOTE_SHA" ]] || { echo "HEAD $LOCAL_SHA != origin/main $REMOTE_SHA — push first (the server builds origin/main)"; exit 1; }
echo "deploying $LOCAL_SHA"

ssh -o ConnectTimeout=10 "$SERVER" true || { echo "cannot reach $SERVER over ssh alias (tailnet up?)"; exit 1; }

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  log "dry run — stopping before any remote change"
  exit 0
fi

# --- remote build + restart --------------------------------------------------
log "remote: pull, build, restart"
ssh -o ConnectTimeout=20 "$SERVER" bash -euo pipefail <<'REMOTE'
  cd /opt/timeline-src
  git fetch --quiet origin main
  git reset --hard origin/main
  echo "at $(git rev-parse --short HEAD)"

  # cx23 has too little RAM for next build; add swap for the duration.
  if [ ! -f /swapfile-build ]; then
    fallocate -l 4G /swapfile-build
    chmod 600 /swapfile-build
    mkswap -q /swapfile-build
    swapon /swapfile-build
    echo "swap on"
  fi
  trap 'swapoff /swapfile-build 2>/dev/null || true; rm -f /swapfile-build' EXIT

  # Derive the image tag from the compose file rather than hardcoding it. The
  # vault runbook said timeline-edge:v2 while compose actually referenced v12,
  # so a "successful" deploy rebuilt an unused tag and left the old container
  # running for 11 days.
  IMAGE=$(grep -E '^\s*image:' /opt/timeline/docker-compose.yml | head -1 | sed -E 's/.*image:\s*//; s/["'"'"']//g')
  echo "compose image: $IMAGE"

  docker image inspect "$IMAGE" >/dev/null 2>&1 && docker tag "$IMAGE" "${IMAGE}-prev"

  cd /opt/timeline-src/frontend
  docker build -q -t "$IMAGE" .

  cd /opt/timeline
  docker compose up -d --force-recreate
  docker compose ps
REMOTE

# --- verify ------------------------------------------------------------------
log "waiting for healthy container"
ssh "$SERVER" 'for i in $(seq 1 30); do
  s=$(docker inspect -f "{{.State.Health.Status}}" timeline-app 2>/dev/null || echo none)
  [ "$s" = healthy ] && { echo healthy; exit 0; }
  sleep 4
done; echo "NOT healthy: $s"; docker logs --tail 40 timeline-app; exit 1'

log "verifying live routes"
FAIL=0
for path in / /updates /methodology /era/era-16 /era/era-120 /year/1610 /data/eras/index.json; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://timeline.sumarhus.com$path")
  printf '  %-28s %s\n' "$path" "$code"
  [[ "$code" == "200" ]] || FAIL=1
done

# Assert the live payload actually changed. Route 200s alone cannot tell a
# fresh deploy from a stale container still happily serving the old build.
read -r LIVE_ERAS LIVE_SCHEMA < <(curl -s https://timeline.sumarhus.com/data/eras/index.json \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['registry']), d.get('schema_version'))")
LOCAL_ERAS=$(python3 -c "import json; print(len(json.load(open('frontend/public/data/eras/index.json'))['registry']))")
echo "  live era index: $LIVE_ERAS eras, schema $LIVE_SCHEMA (local: $LOCAL_ERAS)"
if [[ "$LIVE_ERAS" != "$LOCAL_ERAS" ]]; then
  echo "STALE DEPLOY: live serves $LIVE_ERAS eras but this commit has $LOCAL_ERAS."
  echo "The container is probably running an image tag the build did not update."
  FAIL=1
fi

[[ "$FAIL" == "0" ]] || { echo "SOME ROUTES FAILED"; exit 1; }
log "deployed $LOCAL_SHA — all checked routes 200"
echo "NOTE: HTTP 200 is not visual verification. Look at the pages before calling it done."
