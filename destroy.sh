#!/usr/bin/env bash
# Teardown: stops Docker, stops Glue jobs + triggers, then `terraform destroy`.
# Designed to be safe to run multiple times.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { printf "${BLUE}▶ %s${NC}\n" "$*"; }
ok()   { printf "${GREEN}✓ %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
err()  { printf "${RED}✗ %s${NC}\n" "$*" >&2; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
INFRA="$ROOT/infra"

# ─────────────────────────  confirm  ─────────────────────────
echo "${YELLOW}This will:${NC}"
echo "  • stop the 3 Docker services"
echo "  • stop running Glue jobs + pause schedule"
echo "  • run \`terraform destroy\` on AWS (VPC, EC2, RDS, S3, Glue) + Azure (Event Hubs)"
echo "  • S3 bucket will be EMPTIED and DELETED (force_destroy)"
echo "  • RDS will be DELETED (skip_final_snapshot, no backup)"
echo
read -rp "Type 'destroy' to confirm: " ans
[ "$ans" = "destroy" ] || { err "aborted"; exit 1; }

# ─────────────────────────  AWS region/creds  ─────────────────────────
if [ -z "${AWS_DEFAULT_REGION:-}" ]; then
  if [ -f "$ROOT/.env" ]; then
    REGION=$(grep -E '^AWS_REGION=' "$ROOT/.env" | cut -d= -f2 || true)
    export AWS_DEFAULT_REGION="${REGION:-us-east-1}"
  else
    export AWS_DEFAULT_REGION=us-east-1
  fi
fi

# Pull project/env from tfvars if present (for resource-name guesses)
PROJECT=accident-severity; ENV=dev
if [ -f "$INFRA/terraform.tfvars" ]; then
  P=$(grep -E '^project_name' "$INFRA/terraform.tfvars" | cut -d'"' -f2 || true); PROJECT="${P:-$PROJECT}"
  E=$(grep -E '^environment'  "$INFRA/terraform.tfvars" | cut -d'"' -f2 || true); ENV="${E:-$ENV}"
fi
PFX="$PROJECT-$ENV"

# ─────────────────────────  stop Docker stack on EC2 (best-effort)  ─────────────────────────
log "stop Docker stack on EC2 (best-effort, may fail if EC2 already gone)"
EC2_IP=$( ( cd "$INFRA" && terraform output -raw ec2_public_ip ) 2>/dev/null || echo "")
SSH_KEY_PATH="$INFRA/producer-key.pem"
if [ -n "$EC2_IP" ] && [ -f "$SSH_KEY_PATH" ]; then
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "ec2-user@$EC2_IP" \
      'cd /home/ec2-user/app && sudo docker compose down --volumes --remove-orphans 2>/dev/null || true' \
      >/dev/null 2>&1 && ok "EC2 containers stopped" || warn "couldn't reach EC2 (or already down) — continuing"
else
  warn "no EC2 IP / SSH key in TF state — skipping EC2 docker stop"
fi

# ─────────────────────────  stop Glue triggers + jobs  ─────────────────────────
log "stop Glue ML training trigger"
for tname in "$PFX-ml-train-every-15m" "$PFX-ml-train-every-3h"; do
  aws glue stop-trigger --name "$tname" >/dev/null 2>&1 && ok "  paused $tname" || true
done

log "stop running Glue jobs"
for j in accident-kpi-geo accident-conditions accident-hotspots vehicle-profile accident-vehicle-demographics ml-train-severity; do
  name="$PFX-$j"
  info=$(aws glue get-job-runs --job-name "$name" --max-items 1 --output json 2>/dev/null \
         | python3 -c 'import sys,json; d=json.load(sys.stdin); r=d.get("JobRuns") or [{}]; print(r[0].get("JobRunState",""), r[0].get("Id",""))' 2>/dev/null || true)
  state=$(echo "$info" | awk '{print $1}')
  id=$(echo "$info" | awk '{print $2}')
  if [ "$state" = "RUNNING" ] || [ "$state" = "STARTING" ]; then
    aws glue batch-stop-job-run --job-name "$name" --job-run-ids "$id" >/dev/null 2>&1 \
      && ok "  stopped $name"
  fi
done

# ─────────────────────────  terraform destroy  ─────────────────────────
log "terraform destroy (~7–10 min: RDS + EH deletion dominates)"
if [ ! -d "$INFRA" ]; then err "no infra/ folder"; exit 1; fi

( cd "$INFRA" && terraform destroy -auto-approve -input=false ) | tail -10
ok "terraform destroy complete"

# ─────────────────────────  cleanup local artifacts  ─────────────────────────
log "cleanup local artifacts"
rm -f "$INFRA/glue-rds.tfplan" "$INFRA/ml.tfplan" "$ROOT/.env" 2>/dev/null || true
rm -f "$INFRA/producer-key.pem" 2>/dev/null || true
ok "removed plan files, .env, ssh key"

echo
echo "══════════════════════  ALL DOWN  ══════════════════════"
echo "  Everything torn down. To bring it back:  bash setup.sh"
echo "══════════════════════════════════════════════════════"
