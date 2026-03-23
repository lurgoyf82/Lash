# LASH (Local AI Software House)

Installer/deployer **bare-metal** (Debian 13) per uno stack locale composto da:

- Gateway **FastAPI** (servito con **Uvicorn**)
- UI **Streamlit**
- Worker **Celery**
- Proxy **LiteLLM**
- **PostgreSQL** e **Redis**
- Monitoring **Prometheus** + **Grafana**
- Gestione servizi via **systemd**

Il flusso principale è gestito da `deploy_lash.sh`, che esegue gli installer modulari `install_*.sh`, genera le unità systemd e avvia i servizi.

## Requisiti

- Debian 13
- Accesso `sudo`
- Connettività di rete (per `apt-get`/`pip`)
- Porte (default, configurabili in `config/*.json`):
  - FastAPI/Uvicorn: `8000`
  - Streamlit: `8501`
  - LiteLLM: `4000`
  - Redis: `6379`
  - PostgreSQL: `5432`
  - Prometheus: `9090`
  - Grafana: `3000`

`deploy_lash.sh` verifica i conflitti di porta prima di procedere.

## Quick start (deploy)

Eseguire l’orchestratore:

```bash
sudo bash deploy_lash.sh
```

Lo script:

1. Controlla le porte (leggendo eventuali override da `config/*.json`)
2. Esegue gli installer in ordine di dipendenze (Python, PostgreSQL, Redis, librerie/app)
3. Inizializza il DB PostgreSQL e, se presente `alembic.ini`, esegue `alembic upgrade head`
4. Scrive le unità systemd
5. Abilita e avvia i servizi
6. Esegue health check e smoke test

## Struttura repository

- `deploy_lash.sh`: orchestrazione end-to-end (install, migrazioni, unit, avvio, check)
- `lib_installer.sh`: funzioni comuni (JSON via `jq`, prompt, check porte, delega installer)
- `install_*.sh`: installer modulari
- `config/`: configurazioni generate/aggiornate dagli installer (JSON)

## Servizi systemd

Servizi avviati dal deploy:

- `lash-api` (FastAPI/Uvicorn)
- `lash-streamlit`
- `lash-celery`
- `lash-litellm`
- `prometheus`
- `grafana-server`

Comandi utili:

```bash
sudo systemctl status lash-api
sudo journalctl -u lash-api -f

sudo systemctl status lash-streamlit
sudo journalctl -u lash-streamlit -f

sudo systemctl status lash-celery
sudo journalctl -u lash-celery -f

sudo systemctl status lash-litellm
sudo journalctl -u lash-litellm -f
```

## Configurazione

Le configurazioni vengono gestite come JSON in `config/` e vengono create/aggiornate dagli installer. File tipici:

- `config/python.json`
- `config/uvicorn.json`
- `config/streamlit.json`
- `config/litellm.json`
- `config/celery.json`
- `config/sqlalchemy.json`
- `config/postgresql.json`
- `config/redis.json`

### Variabili d’ambiente (`.env`)

Le unità systemd caricano opzionalmente:

- `./.env` (nella directory di installazione)
- per Celery anche `./.env.celery` (auto-generato dal deploy con `CELERY_BROKER_URL`)

PostgreSQL ora salva anche una `password` inline in `config/postgresql.json` dopo aver validato la connessione con un test reale via `psql`. Rimane compatibile con `password_env` per i record legacy o per chi preferisce ancora passare da variabili d’ambiente. Redis continua invece a usare `password_env`.

Durante `deploy_lash.sh`, se una porta è già occupata, il flusso non si ferma più al warning: propone se terminare il processo che sta occupando la porta oppure se scegliere e salvare una porta alternativa nel relativo file `config/*.json`.

## Troubleshooting

- **Conflitti porte**: `deploy_lash.sh` può ora chiudere il processo che occupa la porta o salvare una porta alternativa; in alternativa si può ancora modificare manualmente `config/*.json` e rieseguire il deploy.
- **Un servizio non parte**: controllare `journalctl -u <service>`.
- **Migrazioni Alembic**: se `alembic.ini` non è presente, le migrazioni vengono saltate.

## Licenza

Vedi repository.
