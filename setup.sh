#!/usr/bin/env bash
# One-shot provisioning: collects credentials, applies Terraform, wires up the
# stack (S3 JAR, Postgres schema, Glue jobs), and starts the 3 Docker services.
#
# Idempotent: re-running picks up where it left off (terraform handles drift).
#
# Required on host:  bash, terraform, aws, az, jq, ssh, curl, python3, docker, docker compose
set -euo pipefail

# ─────────────────────────  helpers  ─────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { printf "${BLUE}▶ %s${NC}\n" "$*"; }
ok()   { printf "${GREEN}✓ %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
err()  { printf "${RED}✗ %s${NC}\n" "$*" >&2; }

prompt() {
  local var="$1" msg="$2" default="${3:-}" secret="${4:-}"
  local val=""
  if [ -n "$default" ]; then msg="$msg [default: $default]"; fi
  if [ "$secret" = "secret" ]; then
    read -rsp "$msg: " val; echo
  else
    read -rp "$msg: " val
  fi
  if [ -z "$val" ] && [ -n "$default" ]; then val="$default"; fi
  if [ -z "$val" ]; then err "value required"; exit 1; fi
  printf -v "$var" '%s' "$val"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "missing: $1 — please install"; exit 1; }
}

# ─────────────────────────  preflight  ─────────────────────────
log "preflight — checking required tools"
for c in terraform aws az ssh scp rsync curl python3; do require_cmd "$c"; done
ok "all tools present"

ROOT="$(cd "$(dirname "$0")" && pwd)"
INFRA="$ROOT/infra"
cd "$ROOT"

# ─────────────────────────  collect inputs  ─────────────────────────
log "collect credentials + config"

prompt AWS_ACCESS_KEY_ID   "AWS access key id"
prompt AWS_SECRET_ACCESS_KEY "AWS secret access key" "" secret
prompt AWS_REGION          "AWS region" "us-east-1"
prompt AZ_SUB              "Azure subscription id (run \`az account show --query id -o tsv\` if unsure)"
prompt PROJECT             "project name (lowercase, dash-separated)" "accident-severity"
prompt ENV                 "environment" "dev"
prompt AZ_LOC              "Azure region for Event Hubs" "southeastasia"
prompt SSH_CIDR            "CIDR allowed to SSH the producer EC2 (use 0.0.0.0/0 for open)" "0.0.0.0/0"
prompt RDS_CIDR_EXTRA      "extra CIDR allowed to reach RDS:5432 (your laptop ip/32, or 0.0.0.0/0)" "0.0.0.0/0"

# auto-generate a strong RDS password
RDS_PASSWORD=$(python3 -c 'import secrets,string; alphabet=string.ascii_letters+string.digits; print("".join(secrets.choice(alphabet) for _ in range(24)))')
ok "generated 24-char RDS password"

# ─────────────────────────  Azure CLI login  ─────────────────────────
log "Azure CLI login (device code flow — opens browser)"
if ! az account show --subscription "$AZ_SUB" >/dev/null 2>&1; then
  az login --use-device-code
fi
az account set --subscription "$AZ_SUB"
ok "Azure subscription set"

# ─────────────────────────  write terraform.tfvars  ─────────────────────────
log "write infra/terraform.tfvars"
cat > "$INFRA/terraform.tfvars" <<EOF
aws_region              = "$AWS_REGION"
project_name            = "$PROJECT"
environment             = "$ENV"
ssh_allowed_cidrs       = ["$SSH_CIDR"]
azure_subscription_id   = "$AZ_SUB"
azure_location          = "$AZ_LOC"
rds_password            = "$RDS_PASSWORD"
rds_extra_ingress_cidrs = ["$RDS_CIDR_EXTRA"]
EOF
ok "tfvars written"

# ─────────────────────────  AWS env for the rest of the script  ─────────────────────────
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$AWS_REGION"
aws sts get-caller-identity >/dev/null
ok "AWS credentials valid"

# ─────────────────────────  terraform  ─────────────────────────
log "terraform init"
( cd "$INFRA" && terraform init -input=false -upgrade ) | tail -5
log "terraform apply (~6–8 min: RDS creation dominates)"
( cd "$INFRA" && terraform apply -auto-approve -input=false ) | tail -5
ok "terraform apply done"

# ─────────────────────────  outputs  ─────────────────────────
log "read outputs"
get_out() { ( cd "$INFRA" && terraform output -raw "$1" ); }
EC2_IP=$(get_out ec2_public_ip)
S3_BUCKET=$(get_out s3_bucket)
RDS_HOST=$(get_out rds_endpoint)
RDS_PORT=$(get_out rds_port)
RDS_DB=$(get_out rds_db_name)
EH_BOOT=$(get_out eventhub_bootstrap_server)
EH_CONN=$(get_out eventhub_connection_string)
SSH_KEY=$(get_out ssh_private_key_path)
chmod 600 "$INFRA/$SSH_KEY" 2>/dev/null || true
ok "EC2=$EC2_IP  RDS=$RDS_HOST  S3=$S3_BUCKET"

# ─────────────────────────  upload CSV sample data to S3 ─────────────────────────
log "upload accident + vehicle CSVs to S3 (producer reads from here)"
if ! aws s3 ls "s3://$S3_BUCKET/accidents/Accident_Information.csv" >/dev/null 2>&1; then
  aws s3 cp "$ROOT/data/Accident_Information.csv" "s3://$S3_BUCKET/accidents/Accident_Information.csv" --quiet
fi
if ! aws s3 ls "s3://$S3_BUCKET/vehicles/Vehicle_Information.csv" >/dev/null 2>&1; then
  aws s3 cp "$ROOT/data/Vehicle_Information.csv" "s3://$S3_BUCKET/vehicles/Vehicle_Information.csv" --quiet
fi
ok "CSVs in S3"

# ─────────────────────────  Postgres JDBC JAR  ─────────────────────────
log "upload Postgres JDBC JAR for Glue"
if ! aws s3 ls "s3://$S3_BUCKET/glue/scripts/jars/postgresql-42.7.3.jar" >/dev/null 2>&1; then
  curl -sL -o /tmp/postgresql-42.7.3.jar \
    https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.3/postgresql-42.7.3.jar
  aws s3 cp /tmp/postgresql-42.7.3.jar \
    "s3://$S3_BUCKET/glue/scripts/jars/postgresql-42.7.3.jar" --quiet
  ok "uploaded JDBC jar"
else
  ok "JDBC jar already present"
fi

# ─────────────────────────  apply Postgres schema  ─────────────────────────
log "apply Postgres schema via EC2 (same VPC as RDS)"
scp -i "$INFRA/$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "$INFRA/sql/init_dashboard_schema.sql" "ec2-user@$EC2_IP:/tmp/init_dashboard_schema.sql" >/dev/null

ssh -i "$INFRA/$SSH_KEY" -o StrictHostKeyChecking=no "ec2-user@$EC2_IP" \
    'which psql >/dev/null 2>&1 || (sudo amazon-linux-extras enable postgresql14 >/dev/null && sudo yum install -y postgresql >/dev/null)' >/dev/null

ssh -i "$INFRA/$SSH_KEY" -o StrictHostKeyChecking=no "ec2-user@$EC2_IP" \
    "PGPASSWORD='$RDS_PASSWORD' psql -h $RDS_HOST -U dashboard_admin -d $RDS_DB -f /tmp/init_dashboard_schema.sql" >/dev/null
ok "Postgres schema applied"

# ─────────────────────────  start Glue jobs  ─────────────────────────
log "start 5 Glue streaming jobs"
for j in accident-kpi-geo accident-conditions accident-hotspots vehicle-profile accident-vehicle-demographics; do
  name="$PROJECT-$ENV-$j"
  state=$(aws glue get-job-runs --job-name "$name" --max-items 1 --query 'JobRuns[0].JobRunState' --output text 2>/dev/null | head -1 || echo "NONE")
  if [ "$state" = "RUNNING" ] || [ "$state" = "STARTING" ]; then
    ok "  $name already $state"
  else
    aws glue start-job-run --job-name "$name" --output text --query JobRunId >/dev/null
    ok "  started $name"
  fi
done

# ─────────────────────────  write .env (used on EC2 for docker compose)  ─────────────────────────
log "write .env for EC2 docker compose"
cat > "$ROOT/.env" <<EOF
AWS_REGION=$AWS_REGION
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
S3_BUCKET=$S3_BUCKET
DB_HOST=$RDS_HOST
DB_PORT=$RDS_PORT
DB_NAME=$RDS_DB
DB_USER=dashboard_admin
DB_PASS=$RDS_PASSWORD
MODEL_KEY=models/severity_classifier.joblib
MODEL_CACHE_TTL_SEC=300
KAFKA_BROKERS=$EH_BOOT
KAFKA_SASL_USERNAME=\$ConnectionString
KAFKA_SASL_PASSWORD=$EH_CONN
PRODUCER_RATE=100
PRODUCER_MAX_RECORDS=0
EOF
chmod 600 "$ROOT/.env"
ok ".env written (chmod 600)"

# ─────────────────────────  deploy Docker stack to EC2  ─────────────────────────
log "install Docker on EC2 (idempotent)"
SSH_KEY_FULL="$INFRA/$SSH_KEY"
SSH_OPTS=(-i "$SSH_KEY_FULL" -o StrictHostKeyChecking=no -o ConnectTimeout=10)
ssh "${SSH_OPTS[@]}" "ec2-user@$EC2_IP" 'bash -s' <<'REMOTE'
set -e
if ! command -v docker >/dev/null 2>&1; then
  sudo amazon-linux-extras install -y docker >/dev/null
  sudo systemctl enable --now docker
  sudo usermod -aG docker ec2-user
fi
if ! docker compose version >/dev/null 2>&1; then
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  sudo curl -sSL "https://github.com/docker/compose/releases/download/v2.32.1/docker-compose-linux-$(uname -m)" \
       -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi
REMOTE
ok "Docker + Compose ready on EC2"

log "disable systemd producer (replaced by Docker container)"
ssh "${SSH_OPTS[@]}" "ec2-user@$EC2_IP" \
  'sudo systemctl disable --now producer 2>/dev/null || true' >/dev/null
ok "systemd producer disabled"

log "sync code to EC2 (producer/, dashboard/, ml_predict/, compose, .env)"
ssh "${SSH_OPTS[@]}" "ec2-user@$EC2_IP" 'mkdir -p /home/ec2-user/app' >/dev/null
# rsync needs a single -e string; build it from the same key path.
RSYNC_SSH="ssh -i $SSH_KEY_FULL -o StrictHostKeyChecking=no -o ConnectTimeout=10"
for dir in producer dashboard ml_predict; do
  rsync -az --delete -e "$RSYNC_SSH" \
    --exclude='.venv' --exclude='__pycache__' --exclude='*.pyc' \
    "$ROOT/$dir" "ec2-user@$EC2_IP:/home/ec2-user/app/"
done
scp "${SSH_OPTS[@]}" "$ROOT/docker-compose.ec2.yml" "ec2-user@$EC2_IP:/home/ec2-user/app/docker-compose.yml" >/dev/null
scp "${SSH_OPTS[@]}" "$ROOT/.env"                    "ec2-user@$EC2_IP:/home/ec2-user/app/.env" >/dev/null
ok "code synced to /home/ec2-user/app/"

log "build + up docker stack on EC2 (producer + dashboard + ml-predict)"
ssh "${SSH_OPTS[@]}" "ec2-user@$EC2_IP" 'cd /home/ec2-user/app && sudo docker compose build --quiet && sudo docker compose up -d' | tail -8
ok "containers running on EC2"

# ─────────────────────────  summary  ─────────────────────────
echo
echo "══════════════════════  ALL UP  ══════════════════════"
echo "  Dashboard          : http://$EC2_IP:8000"
echo "  ml-predict API     : http://$EC2_IP:8001"
echo "  Kafka UI           : http://$EC2_IP:8080"
echo "  Producer EC2       : ssh -i infra/$SSH_KEY ec2-user@$EC2_IP"
echo "  RDS endpoint       : $RDS_HOST"
echo "  S3 bucket          : s3://$S3_BUCKET/"
echo "  RDS password       : $RDS_PASSWORD"
echo "  .env file (local)  : $ROOT/.env"
echo
echo "Logs on EC2:"
echo "  ssh -i infra/$SSH_KEY ec2-user@$EC2_IP \\"
echo "    'cd /home/ec2-user/app && sudo docker compose logs -f'"
echo
echo "Glue jobs warming up. First aggregations land in Postgres in 2-5 min."
echo "When done, tear down with: bash destroy.sh"
echo "══════════════════════════════════════════════════════"
