FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY producer.py .

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    KAFKA_SASL_USERNAME='$ConnectionString' \
    RATE=100 \
    MAX_RECORDS=0

# Sane defaults — override at run time via env vars / docker-compose:
#   KAFKA_BROKERS, KAFKA_SASL_PASSWORD, S3_BUCKET, AWS_REGION

CMD ["python", "producer.py"]
