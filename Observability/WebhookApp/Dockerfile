FROM python:3.12-alpine

WORKDIR /app
COPY main.py .

RUN adduser -D -u 1000 appuser
USER appuser

EXPOSE 8080
ENV LISTEN_PORT=8080
ENV WEBHOOK_PATH=/webhook

CMD ["python", "-u", "main.py"]
