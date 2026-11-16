.PHONY: help up down logs ps drift-on drift-off retrain alerts test lint local-install local-train local-api local-sim local-drift local-monitor clean
COMPOSE = docker compose

help:            ## list targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

# ---------------------------------------------------------------- full stack (Docker)
up:              ## build and start the whole platform
	$(COMPOSE) up -d --build
down:            ## stop everything (keeps data volumes)
	$(COMPOSE) down
clean:           ## stop everything and delete all volumes
	$(COMPOSE) down -v
logs:            ## follow logs of the ML services
	$(COMPOSE) logs -f api processor producer monitor
ps:              ## service status
	$(COMPOSE) ps
drift-on:        ## inject data/concept drift into the live stream
	$(COMPOSE) exec redis redis-cli set control:drift 1
drift-off:       ## return the stream to the normal regime
	$(COMPOSE) exec redis redis-cli set control:drift 0
retrain:         ## manual feedback retraining (also runs automatically on drift)
	$(COMPOSE) run --rm init-train python -m src.training.train --with-feedback
alerts:          ## tail the fraud-alerts Kafka topic
	$(COMPOSE) exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic fraud-alerts

# ---------------------------------------------------------------- local mode (no Docker)
local-install:   ## create .venv and install dev dependencies
	python3 -m venv .venv && .venv/bin/pip install -U pip && .venv/bin/pip install -r requirements-dev.txt
local-train:     ## train + register the first champion (SQLite MLflow)
	.venv/bin/python -m src.training.train
local-api:       ## serve the champion on :8000
	.venv/bin/uvicorn src.serving.app:app --port 8000
local-sim:       ## replay 5000 transactions through the API
	.venv/bin/python scripts/simulate_local.py --events 5000
local-drift:     ## 3000 normal then 5000 drifted transactions
	.venv/bin/python scripts/simulate_local.py --events 8000 --drift-after 3000
local-monitor:   ## one drift check (retrains automatically if needed)
	.venv/bin/python -m src.monitoring.drift_monitor --once

test:            ## unit + integration tests
	.venv/bin/python -m pytest -q
lint:            ## static analysis
	.venv/bin/ruff check .
