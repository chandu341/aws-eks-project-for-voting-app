# ==============================================================================
# Dockerfile for Vote Frontend Service (Python / Flask)
# ==============================================================================
FROM python:3.11-slim

# Prevent python from writing pyc files and enable unbuffered logging
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Install dependencies in a single cached layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source code
COPY . .

EXPOSE 80

# Run with production Gunicorn WSGI server
CMD ["gunicorn", "--bind", "0.0.0.0:80", "--workers", "2", "--threads", "4", "app:app"]
