# Real-Time Accident Severity — Infra

Terraform stack for the streaming pipeline. **Cross-cloud**: AWS for compute + storage, Azure Event Hubs (Kafka surface) for streaming.

## Layout

```
infra/
├── providers.tf            # aws + azurerm + tls + local + random
├── variables.tf
├── main.tf                 # wires the modules together
├── outputs.tf
├── terraform.tfvars.example
└── modules/
    ├── vpc/         # AWS VPC + IGW + public subnets across N AZs
    ├── s3/          # AWS data lake bucket (raw / processed / checkpoints / logs)
    ├── ec2/         # AWS producer EC2 (Kafka client + S3 access)
    ├── eventhubs/   # Azure Event Hubs namespace + topics (Kafka surface)
    ├── kafka/       # (legacy, unused) AWS MSK cluster
    └── spark/       # AWS EMR cluster running Spark
```

## What you get

- **AWS VPC** — `/16` VPC, one public subnet per AZ, IGW + default route.
- **AWS S3** — one encrypted, versioned bucket with `raw/`, `processed/`, `checkpoints/`, `logs/` prefixes.
- **AWS EC2** — Amazon Linux 2 instance with Java 11, Python, `kafka-python`, `boto3`; IAM role with S3 access; Terraform-generated SSH keypair.
- **Azure Event Hubs (Kafka surface)** — namespace + two event hubs (`accident-raw`, `vehicles-raw`) reachable as Kafka topics on `<namespace>.servicebus.windows.net:9093` (SASL_SSL).
- **AWS EMR (Spark)** — Spark/Hadoop/Hive cluster, master + N core nodes, logs to S3.

The EC2 producer talks to Azure Event Hubs over the public internet (TLS). No VPN required.

## Prerequisites

- AWS credentials (env vars or `~/.aws/credentials`).
- Azure CLI logged in: `az login`. Get your subscription ID with `az account show --query id -o tsv` and put it in `terraform.tfvars`.

## Usage

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set azure_subscription_id

terraform init
terraform plan
terraform apply
```

## Required inputs

| Variable                | Notes                                                  |
| ----------------------- | ------------------------------------------------------ |
| `azure_subscription_id` | **required** — your Azure subscription ID             |
| `azure_location`        | (optional) defaults to `eastus`                        |
| `eventhub_sku`          | (optional) `Standard` or `Premium` (Basic ≠ Kafka)     |
| `eventhub_partitions`   | (optional) defaults to `4` per topic                   |
| `vpc_cidr`              | (optional) defaults to `10.0.0.0/16`                   |
| `az_count`              | (optional) defaults to `2`                             |
| `ssh_allowed_cidrs`     | (optional) defaults to `["0.0.0.0/0"]`                 |

## Connecting the producer to Event Hubs

After `terraform apply`, SSH in and export the SASL credentials:

```bash
ssh -i "$(terraform output -raw ssh_private_key_path)" ec2-user@$(terraform output -raw ec2_public_ip)

# on the EC2 (or wherever the producer runs):
export KAFKA_BROKERS=$(terraform output -raw eventhub_bootstrap_server)
export KAFKA_SASL_PASSWORD=$(terraform output -raw eventhub_connection_string)
# KAFKA_SASL_USERNAME defaults to "$ConnectionString" — the literal string Event Hubs expects.

python3 producer/producer.py
```

Terraform **generates** a fresh 4096-bit RSA keypair, uploads the public key to AWS as `<project>-<env>-producer-key`, and writes the private key PEM next to the Terraform config (default: `infra/producer-key.pem`, chmod 0600). After `terraform apply`:

```bash
ssh -i "$(terraform output -raw ssh_private_key_path)" ec2-user@$(terraform output -raw ec2_public_ip)
```

The PEM contains a private key — keep it out of git (add `*.pem` to `.gitignore`).

## Notes

- The AWS stack is fully self-contained: it creates its own VPC, subnets, and IGW.
- Azure Event Hubs namespace name is suffixed with a random string for global uniqueness.
- EMR uses `emr-7.1.0` with Spark + Hadoop + Hive; tune in `main.tf` if needed.
- All resources are tagged `Project`, `Environment`, `ManagedBy=terraform`.
- `terraform destroy` will tear the whole stack down (AWS + Azure); the S3 bucket must be empty first.
