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

curl -fsS http://localhost:4000/health/liveliness
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

---

## Errori che impediscono il proseguimento del deploy (stato attuale)

Questa sezione documenta gli errori osservati durante una run reale (`sudo bash deploy_lash.sh` con `LASH_DEBUG=1`) che:
- bloccano l’installazione (stop immediato), oppure
- fanno proseguire il deploy con configurazioni incoerenti/non utilizzabili, causando fallimenti successivi.

### 1) PostgreSQL: validazione credenziali fallita e configurazione salvata “rotta” (non legge/riusa config esistente, e può non scrivere i dati corretti)

Caso osservato: `install_postgresql.sh` rileva un `psql` locale (es. `/usr/bin/psql`) e chiede porta/username/password per testare una connessione reale con:

- host: `127.0.0.1`
- port: `5432`
- user: `postgres`
- query: `SELECT 1;`

Quando la password è errata (o l’istanza è configurata con auth diversa), il test fallisce con:

- `FATAL: password authentication failed for user "postgres"`

A quel punto:
- lo script chiede se riprovare
- se si risponde “no”, stampa un errore tipo: “PostgreSQL connection details were not validated. Aborting.”

Problema grave (persistenza config):
- nonostante la validazione fallita, può comunque finire per scrivere/aggiornare `config/postgresql.json` con un record incompleto (campo porta null, username/password vuoti), per esempio:

postgresql.json
```json
{
  "servers": {
    "pg_375747b2": {
      "id": "pg_375747b2",
      "location": "local",
      "host": "127.0.0.1",
      "port": null,
      "username": "",
      "password": "",
      "password_env": null,
      "version": "17.9",
      "binary_path": "/usr/bin/psql",
      "service_name": "postgresql.service",
      "available": true
    }
  }
}
```

Quindi:
- `postgresql.json` NON contiene `username` e `password` salvate (restano stringhe vuote) e `port` può diventare `null`.
- la configurazione esiste ma è inutilizzabile per gli step successivi.
- inoltre il flag `available: true` è fuorviante, perché il record non rappresenta una connessione valida.

Problema di lettura/riuso della config (UX, “le basi”):
- se esiste già un record per quella installazione (es. match su `binary_path == "/usr/bin/psql"`), prima di chiedere di nuovo tutti i dati dovrebbe comparire un prompt esplicito del tipo:
  - “Esiste già una configurazione per questo PostgreSQL. Vuoi usare quella esistente o modificarla?”
- stato attuale: lo script “aggiorna record esistente” ma non propone davvero un flusso di riuso/modifica guidato; di fatto può richiedere di reinserire credenziali ogni volta e/o lasciare in config dati vuoti.

Effetto sul deploy:
- `deploy_lash.sh` (Step 3: DB init) e `install_sqlalchemy.sh` leggono da `config/postgresql.json` (host/port/user/password). Se port/user/pass sono null/vuoti, i comandi `psql` falliscono e il deploy si interrompe o resta in stato incoerente.

### 2) SQLAlchemy: installazione bloccata da PEP 668 (errore che blocca davvero)

Su Debian 13, il Python di sistema è tipicamente “externally managed” (PEP 668). Questo impedisce l’uso di `pip install` nel site-packages di sistema.

Caso osservato:
- `install_psycopg.sh` prova a installare nel Python selezionato (es. `/usr/bin/python3.13`), riceve l’errore PEP 668 e correttamente fa fallback su un `venv` dedicato.
- `install_sqlalchemy.sh` invece, in Phase 4, tenta direttamente:

```
/usr/bin/python3.13 -m pip install --quiet sqlalchemy
```

che fallisce con:

```
error: externally-managed-environment
...
hint: See PEP 668 for the detailed specification.
```

Effetto sul deploy:
- questo errore FERMA l’installazione di SQLAlchemy, e quindi impedisce di proseguire correttamente con gli step successivi che si aspettano le dipendenze Python installate.

Problema di coerenza tra installer:
- `install_psycopg.sh` ha un fallback a `venv`.
- `install_sqlalchemy.sh` non replica lo stesso pattern e non installa SQLAlchemy nel `venv` già creato/usato, quindi va in errore.

### 3) Prompt `ask_yes_no` usato in modo errato (non blocca sempre, ma produce stato sporco)

In `install_sqlalchemy.sh` c’è una riga del tipo:

```
if ask_yes_no "Enable SQLAlchemy echo (SQL logging)?"; then SA_ECHO_VAL="true"; else SA_ECHO_VAL="false"; fi
```

`ask_yes_no`:
- comunica “sì/no” tramite exit code
- stampa solo messaggi di errore (“Please answer y or n.”) su stdout se l’input non è valido

Con command-substitution `$(...)`:
- eventuali “Please answer y or n.” possono finire dentro `SA_ECHO` (sporcando variabili/logica)
- non è la causa principale del blocco, ma è un segnale di logica di scripting incoerente che può portare a valori sbagliati in `config/sqlalchemy.json`.

---

## Troubleshooting (pratico)

- Se PostgreSQL fallisce autenticazione:
  - verificare password reale dell’utente `postgres` (oppure creare un utente dedicato a LASH)
  - controllare `pg_hba.conf` e metodo di auth (peer/scram/md5) e che il servizio ascolti su 127.0.0.1:5432
  - sistemare `config/postgresql.json` eliminando record con `port:null` e `username/password:""` prima di rilanciare

- Se SQLAlchemy fallisce con PEP 668:
  - serve installare in `venv` (non nel Python di sistema) oppure usare pacchetti OS (`apt`) ove possibile
  - fino a fix nello script, la run continuerà a fallire quando prova `pip install sqlalchemy` su `/usr/bin/python3.13`

## Licenza

Vedi repository.
