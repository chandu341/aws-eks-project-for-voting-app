# ==============================================================================
# Dockerfile for Worker Service (Python / PostgreSQL / Redis)
# ==============================================================================
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Cache dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy worker application
COPY . .

CMD ["python", "-u", "worker.py"]
