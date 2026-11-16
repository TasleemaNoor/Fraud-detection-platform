# Execution Instructions

Two ways to run the project. **Option A** is the full platform (recommended). **Option B** needs no Docker
and no Kafka, and runs the same train -> serve -> drift -> retrain loop on your machine.

---

## Option A - Full platform with Docker (Kafka, Redis, Postgres, MLflow, Prometheus, Grafana)

### Prerequisites
* Docker Desktop (Windows/macOS) or Docker Engine + Compose v2 (Linux)
* About 6 GB of free RAM for Docker, about 6 GB disk, internet access for the first image pull
* (optional) `make`. Without it, use the plain `docker compose` commands shown in brackets.

### 1. Unzip and enter the folder
```bash
unzip fraud-mlops.zip && cd fraud-mlops
```

### 2. Start everything
```bash
docker compose up -d --build        # or: make up
```
First run takes about 5-10 minutes (image builds + downloads). Startup order is automatic: Postgres ->
MLflow -> **initial training** (about 1 minute, registers the first champion) -> API -> Kafka consumers/producer
-> monitor.

### 3. Check it is healthy
```bash
docker compose ps                   # or: make ps
curl http://localhost:8000/ready    # {"status":"ready","model_version":"1"}
docker compose logs -f processor    # "scored 500 transactions" ...
```

### 4. Open the UIs

| What | URL | Login |
|---|---|---|
| **Grafana dashboard** (start here) | http://localhost:3000 | none needed (admin / admin to edit) |
| MLflow (experiments, registry) | http://localhost:5000 | - |
| Scoring API docs (Swagger) | http://localhost:8000/docs | - |
| Kafka UI (topics, messages) | http://localhost:8080 | - |
| Prometheus | http://localhost:9090 | - |
| Drift report (after about 1 min) | `reports/drift_latest.html` | open in a browser |

### 5. Try a prediction yourself
```bash
curl -X POST http://localhost:8000/predict -H "content-type: application/json" -d '{
  "transaction_id":"demo-1","card_id":"card_00042","merchant_category":"jewelry",
  "amount":950,"timestamp":1900000000,"hour":3,"country":"NG","channel":"online","device":"web"}'
```

### 6. Run the drift -> retrain demo
```bash
make drift-on      # or: docker compose exec redis redis-cli set control:drift 1
```
Watch Grafana: *Share of drifted features* rises above 0.30 and *Live recall* drops. Within a few minutes the
monitor logs `triggering feedback retraining`, then `PROMOTED to champion`, and the API logs
`loaded champion v2`. The *Champion model version* tile changes and recall recovers.
```bash
docker compose logs -f monitor api  # see the whole story
make drift-off     # or: docker compose exec redis redis-cli set control:drift 0
```
Retraining needs at least 2000 labelled rows (about 2 minutes at 20 txn/s), and a new model is promoted
only if it passes the quality gate (PR-AUC >= 0.5) and beats the current champion. If the first retrain is
rejected, keep drift on a few more minutes; the monitor retries after a 10-minute cooldown, or run
`make retrain` to trigger it manually.

### 7. Useful commands
```bash
make alerts        # live fraud alerts from Kafka     make logs   # service logs
make down          # stop, keep data                  make clean  # stop and delete all data volumes
```
Tune the stream with `.env` (copy `.env.example`): `EVENTS_PER_SECOND`, `AUTO_RETRAIN`, `MONITOR_INTERVAL_SECONDS`.

---

## Option B - Local run without Docker (Python 3.11+)

Uses SQLite-backed MLflow, an in-memory feature store and a Kafka-less simulator.

```bash
python3 -m venv .venv
source .venv/bin/activate            # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install -r requirements-dev.txt
```

**Terminal 1 - train and serve**
```bash
python -m src.training.train                         # about 1 min, registers champion v1
uvicorn src.serving.app:app --port 8000
```

**Terminal 2 - simulate traffic, inject drift, retrain**
```bash
python scripts/simulate_local.py --events 8000 --drift-after 3000
# recall about 0.9 before the drift, then drops
python -m src.monitoring.drift_monitor --once        # detects drift, retrains, promotes v2
python scripts/simulate_local.py --events 2000 --drift-after 0   # API already serves v2 - recall recovers
```
If the retrain is rejected for too little data (log says "quality gate failed" or "only N feedback rows"),
simulate more drifted traffic (e.g. `--events 6000 --drift-after 0`) and run the monitor again.

Optional UIs: `mlflow ui --backend-store-uri sqlite:///mlflow.db` -> http://localhost:5000 and open
`reports/drift_latest.html`. Optional DVC pipeline: `dvc init --no-scm && dvc repro`.

---

## Run the tests
```bash
pip install -r requirements-dev.txt
python -m pytest -q       # 9 tests: feature parity, generator, train -> serve -> hot-swap -> drift
ruff check .
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Port already in use (3000, 5000, 8000, 8080, 9090) | Stop the other program, or change the left side of the port mapping in `docker-compose.yml` |
| `kafka` unhealthy / restarting | Give Docker at least 6 GB RAM; run `docker compose logs kafka` |
| API stays "starting" | Initial training still running: `docker compose logs -f init-train` |
| Grafana panels empty | Wait about 1 minute for scrapes; confirm targets are UP at http://localhost:9090/targets |
| `reports/drift_latest.html` missing | Monitor needs 500 scored rows first (about 30 seconds of traffic) |
| Changed code, nothing changed | `docker compose up -d --build` |
| Start completely fresh | `make clean` (or `docker compose down -v`), then `docker compose up -d --build` |
| Windows without `make` | Use the `docker compose ...` commands shown in brackets |

## Stop
`docker compose down` (keep data) or `docker compose down -v` (wipe everything).
