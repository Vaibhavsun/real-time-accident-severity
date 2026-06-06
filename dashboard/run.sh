#!/usr/bin/env bash
# Quick-start: install deps + run uvicorn on http://localhost:8000
# Reads DB_PASS from ../infra/terraform.tfvars if not already set.
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${DB_PASS:-}" ]; then
  TFVARS="../infra/terraform.tfvars"
  if [ -f "$TFVARS" ]; then
    export DB_PASS=$(grep '^rds_password' "$TFVARS" | cut -d'"' -f2)
  fi
fi
if [ -z "${DB_PASS:-}" ]; then
  echo "ERROR: DB_PASS not set and ../infra/terraform.tfvars has no rds_password"
  exit 1
fi

if [ ! -d ".venv" ]; then
  python3 -m venv .venv
  ./.venv/bin/pip install -q -r requirements.txt
fi

exec ./.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
