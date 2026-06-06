#!/usr/bin/env bash
#
# Push the producer to the EC2 box and start it against MSK.
# Reads connection details straight from terraform outputs.
#
#   ./deploy.sh            # deploy + start at full speed
#   RATE=200 ./deploy.sh   # throttle to 200 msg/s per stream
#   MAX_RECORDS=1000 ./deploy.sh   # smoke test with 1000 rows per stream
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$HERE/../infra"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/aws-ec2-key.pem}"
SSH_USER="ec2-user"
RATE="${RATE:-0}"
MAX_RECORDS="${MAX_RECORDS:-0}"

echo ">> reading terraform outputs"
EC2_IP=$(terraform -chdir="$INFRA_DIR" output -raw ec2_public_ip)
BROKERS=$(terraform -chdir="$INFRA_DIR" output -raw kafka_bootstrap_brokers)
BUCKET=$(terraform -chdir="$INFRA_DIR" output -raw s3_bucket)
REGION=$(terraform -chdir="$INFRA_DIR" output -raw aws_region 2>/dev/null || echo "us-east-1")

echo "   EC2     : $EC2_IP"
echo "   brokers : $BROKERS"
echo "   bucket  : $BUCKET"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15)

echo ">> copying producer to EC2"
scp "${SSH_OPTS[@]}" "$HERE/producer.py" "$HERE/requirements.txt" \
    "$SSH_USER@$EC2_IP:/home/$SSH_USER/"

echo ">> installing deps and launching producer"
ssh "${SSH_OPTS[@]}" "$SSH_USER@$EC2_IP" bash -s <<EOF
set -euo pipefail
pip3 install --user -q -r /home/$SSH_USER/requirements.txt

export S3_BUCKET="$BUCKET"
export AWS_REGION="$REGION"
export KAFKA_BROKERS="$BROKERS"
export RATE="$RATE"
export MAX_RECORDS="$MAX_RECORDS"

# stop any previous run
pkill -f producer.py || true

nohup python3 /home/$SSH_USER/producer.py > /home/$SSH_USER/producer.log 2>&1 &
sleep 2
echo "producer started (pid \$!). Recent log:"
tail -n 15 /home/$SSH_USER/producer.log || true
EOF

echo ">> done. Watch it with:"
echo "   ssh -i $SSH_KEY $SSH_USER@$EC2_IP 'tail -f producer.log'"
