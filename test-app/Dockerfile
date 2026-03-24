FROM python:3.12-slim

RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

COPY launcher.sh .
RUN chmod +x launcher.sh

USER appuser

# Support both normal workload mode and trouble generator mode
# Set MODE=trouble to run in trouble generator mode
ENV MODE=workload

ENTRYPOINT ["./launcher.sh"]
