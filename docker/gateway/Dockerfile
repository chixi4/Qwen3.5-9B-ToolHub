FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt /app/requirements.txt

RUN python -m pip install --no-cache-dir --upgrade pip wheel \
    && python -m pip install --no-cache-dir -r /app/requirements.txt

COPY . /app

CMD ["python", "run_8080_toolhub_gateway.py", "--host", "0.0.0.0", "--port", "8080"]
