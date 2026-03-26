FROM python:3.12-slim

RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

COPY launcher.sh .
RUN chmod +x launcher.sh

USER appuser

# Application mode: standard (workload) or batch processing
# Set MODE=batch for batch processing mode
ENV MODE=workload

ENTRYPOINT ["./launcher.sh"]
