# Real-Time Fraud Detection - End-to-End MLOps Platform

A production-style, 100 % open-source MLOps project: card transactions stream through Kafka, are scored in
real time by a model served from the MLflow registry, monitored for data drift and performance decay, and
**automatically retrained and hot-swapped** when the world changes.

> New here? Read **[EXECUTION_INSTRUCTIONS.md](EXECUTION_INSTRUCTIONS.md)** - it gets you running in 3 commands.

## Architecture

```
                         ┌──────────────┐   transactions    ┌───────────────────┐
  Producer (simulator) ─▶│ Apache Kafka │──────────────────▶│ Stream processor  │
  drift switch via Redis │   (KRaft)    │◀── predictions ───│ (confluent-kafka) │
                         └──────────────┘◀── fraud-alerts ──└────────┬──────────┘
                                                                     │ POST /predict
                                    ┌────────────────────────────────▼───────────┐
                                    │ FastAPI scoring service                    │
       ┌──────────────┐  features   │  • online features (Redis, 1h windows)     │
       │    Redis     │◀───────────▶│  • champion model loaded from MLflow       │
       └──────────────┘             │  • hot-swaps new champion (no restart)     │
                                    └───────┬─────────────────────────┬──────────┘
                           model registry   │                         │ /metrics
                                    ┌───────▼────────┐        ┌───────▼────────┐
   scored rows + labels  ┌─────────▶│ MLflow server  │        │  Prometheus    │──▶ Grafana
   ┌──────────────┐      │          │ tracking+reg.  │        └───────▲────────┘
   │  PostgreSQL  │◀─────┘          └───────▲────────┘                │ /metrics
   └──────┬───────┘                         │ register / promote      │
          │ last N rows              ┌──────┴───────────────────────┐ │
          └─────────────────────────▶│ Drift monitor (Evidently)    │─┘
                                     │ drift + live recall → retrain│
                                     └──────────────────────────────┘
```

## Tool stack (all open source)

| Concern | Tool |
|---|---|
| Streaming | Apache Kafka 3.8 (KRaft, no ZooKeeper), Kafka UI |
| Online feature store | Redis |
| Model training | scikit-learn, XGBoost, LightGBM |
| Experiment tracking + model registry | MLflow 2.22 (PostgreSQL backend, aliases `champion` / `challenger`) |
| Model serving | FastAPI + Uvicorn, Pydantic validation |
| Data / model drift | Evidently |
| Metrics + dashboards | Prometheus + Grafana (provisioned automatically) |
| Persistence | PostgreSQL (MLflow metadata + scored transactions) |
| Reproducible pipeline | DVC (`dvc.yaml`, `params.yaml`) |
| Quality | pytest, ruff, pre-commit, GitHub Actions CI |
| Packaging | Docker + Docker Compose |

## What makes it "industry-grade"

* **No training/serving skew** - one `compute_features()` function is used offline and online; a test asserts the
  Redis and in-memory feature stores produce identical features.
* **Chronological splits** (no leakage), imbalanced-data handling, PR-AUC as the selection metric.
* **Business-driven threshold** - maximise recall subject to a precision floor (alert budget), stored as a
  model-version tag so serving always uses the threshold the model was validated with.
* **Champion/challenger gate** - a new model must pass a quality gate *and* beat the current champion on the
  same held-out data before the `champion` alias moves.
* **Zero-downtime rollout** - the API polls the registry and swaps the model in memory.
* **Closed feedback loop** - scored transactions + (delayed) ground truth land in Postgres; drift or recall decay
  triggers retraining on recent labelled data; the drift reference is versioned *with* each model.
* **Observability** - latency percentiles, throughput, alert rate, live precision/recall, per-feature drift,
  champion version, retrain count; plus an Evidently HTML report in `reports/drift_latest.html`.
* **At-least-once streaming** with manual offset commits and idempotent DB writes.

## Demo scenario (about 10 minutes)

1. `docker compose up -d --build` - first champion is trained automatically.
2. Open Grafana (http://localhost:3000): ~20 txn/s, recall ~0.85-0.95, precision around the 0.5 floor.
3. `make drift-on` - spending patterns and fraud tactics change (bigger/online spend; fraud becomes small
   "card-testing" bursts).
4. Within 1-3 minutes: *drift share* jumps above 0.30, *live recall* collapses.
5. The monitor retrains on recent labelled feedback, promotes the better model, and the API hot-swaps it;
   recall recovers. Watch the *Champion model version* tile change.
6. Open `reports/drift_latest.html` for the Evidently analysis, and MLflow (http://localhost:5000) for runs.

## Repository layout

```
src/
  common/      config (env-driven), schema/feature contract, SQL layer
  data/        synthetic generator (+ drift regime), dataset materialisation (DVC stage)
  features/    feature computation + Redis / in-memory stores
  training/    train.py - candidates, MLflow logging, registry, promotion gate
  serving/     FastAPI app + Prometheus metrics + model hot-swap
  streaming/   Kafka producer, stream processor
  monitoring/  Evidently drift + live performance + auto-retrain
docker/        Dockerfiles, Postgres init, Prometheus, Grafana provisioning + dashboard
scripts/       simulate_local.py (Kafka-less replay for local mode)
tests/         feature parity, generator, train->serve->hot-swap->drift integration
params.yaml    all hyper-parameters / thresholds     dvc.yaml  pipeline
```

## Configuration

Hyper-parameters, quality gate, drift thresholds and retraining cooldown live in `params.yaml`. Runtime
settings (stream rate, auto-retrain on/off, monitor interval) are env vars - see `.env.example`.

## Honest limitations / next steps for real production

* Data is synthetic and the ground-truth label arrives with the event; in reality labels arrive days later
  (chargebacks) - swap the label source in `processor.py` for a delayed join.
* Single-node Kafka/Postgres/Redis; use managed or clustered services, TLS and secrets management.
* MLflow artifacts use a Docker volume; point `--artifacts-destination` at S3/MinIO/GCS for production.
* Scoring holds a lock around feature read/update (single worker) for correctness; scale out with
  partition-keyed consumers or atomic Redis Lua scripts.
* Orchestration is event-driven from the monitor; for scheduled/complex DAGs add Airflow or Prefect.
* Deploy on Kubernetes (Helm) with an HPA on the API; add canary/shadow serving for challengers.
