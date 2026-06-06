#!/usr/bin/env bash
# Downloads UK Road Safety dataset from Kaggle, filters pre-2005 vehicle records.
#
# Requirements:
#   pip install kaggle
#   export KAGGLE_USERNAME=your_username
#   export KAGGLE_KEY=your_api_key
#
# Or place ~/.kaggle/kaggle.json with {"username":"...","key":"..."}

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { printf "${GREEN}▶ %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
err()  { printf "${RED}✗ %s${NC}\n" "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$ROOT/data"
DATASET="tsiaras/uk-road-safety-accidents-and-vehicles"

# ── preflight ──────────────────────────────────────────────────────────────────
command -v kaggle >/dev/null 2>&1 || err "kaggle CLI not found. Run: pip install kaggle"
command -v python3 >/dev/null 2>&1 || err "python3 not found"

if [ -z "${KAGGLE_USERNAME:-}" ] || [ -z "${KAGGLE_KEY:-}" ]; then
  if [ ! -f "$HOME/.kaggle/kaggle.json" ]; then
    err "Kaggle credentials not found.\nSet KAGGLE_USERNAME + KAGGLE_KEY env vars\nOR place credentials in ~/.kaggle/kaggle.json"
  fi
fi

mkdir -p "$DATA_DIR"

# ── download ───────────────────────────────────────────────────────────────────
log "downloading dataset: $DATASET"
kaggle datasets download -d "$DATASET" -p "$DATA_DIR" --unzip

# ── verify files ───────────────────────────────────────────────────────────────
[ -f "$DATA_DIR/Accident_Information.csv" ] || err "Accident_Information.csv not found after download"
[ -f "$DATA_DIR/Vehicle_Information.csv"  ] || err "Vehicle_Information.csv not found after download"

ACC_ROWS=$(wc -l < "$DATA_DIR/Accident_Information.csv")
VEH_ROWS=$(wc -l < "$DATA_DIR/Vehicle_Information.csv")
log "downloaded: Accident_Information.csv ($ACC_ROWS lines)"
log "downloaded: Vehicle_Information.csv  ($VEH_ROWS lines)"

# ── sort + filter pre-2005 vehicle records ─────────────────────────────────────
log "sorting both CSVs by Accident_Index and removing pre-2005 vehicle records..."

python3 - <<'PYEOF'
import pandas as pd, os, sys

data_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
acc_path = os.path.join(data_dir, "Accident_Information.csv")
veh_path = os.path.join(data_dir, "Vehicle_Information.csv")

print("  sorting Accident_Information.csv...")
acc = pd.read_csv(acc_path, low_memory=False)
acc.sort_values("Accident_Index", inplace=True)
acc.to_csv(acc_path, index=False)
print(f"  accidents: {len(acc):,} rows (sorted)")

print("  sorting + filtering Vehicle_Information.csv...")
veh = pd.read_csv(veh_path, low_memory=False, encoding="latin-1")
before = len(veh)
veh = veh[~veh["Accident_Index"].astype(str).str.startswith("2004")]
veh.sort_values("Accident_Index", inplace=True)
veh.to_csv(veh_path, index=False, encoding="utf-8")
print(f"  vehicles: {before:,} → {len(veh):,} rows (removed {before - len(veh):,} pre-2005 records)")
PYEOF

log "data ready in $DATA_DIR/"
echo ""
echo "  Accident_Information.csv  →  $(wc -l < "$DATA_DIR/Accident_Information.csv") lines"
echo "  Vehicle_Information.csv   →  $(wc -l < "$DATA_DIR/Vehicle_Information.csv") lines"
echo ""
log "done! you can now run setup.sh"
