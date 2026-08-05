# photovault-k8s

Manifest Kubernetes per il deploy di photovault sul cluster di casa (TalosOS a nodo singolo).

Kustomize piatto, senza base/overlay e senza Helm, come `reimagined-disco-k8s`.

## Struttura

```
k8s/
├── kustomization.yaml    # resources + blocco images: (i tag reali li scrive la CI)
├── argocd.yaml           # Application — FUORI dalla kustomization, applicata a mano una volta
├── namespace.yaml
├── postgres.yaml         # PV hostPath + PVC + Deployment
├── services.yaml         # postgres, ui-svc, api-svc
├── api.yaml
├── ui.yaml
├── cronjob-scan.yaml     # due CronJob: coda ogni 15', scansione notturna
├── cronjob-dedup.yaml
├── cronjob-label.yaml    # sospeso: photovault-label è la fase 5
├── manual/               # segnaposto ${...}, applicati con ./apply-manual.sh
│   ├── storage.yaml      # due PV+PVC SMB (ro e rw) — ${NAS_SHARE}
│   └── ingress.yaml      # Ingress — ${PHOTOVAULT_HOST}
└── secrets/              # SOPS+age, applicati con ./decrypt.sh + kubectl
    ├── kustomization.yaml
    ├── secrets.yaml      # TOKEN
    └── secrets-pg.yaml   # PGDATABASE / PGUSER / PGPASSWORD
```

### Cosa sta fuori da ArgoCD, e perché

Due cartelle, per due motivi diversi, entrambi verificabili:

| Cartella | Perché ArgoCD non può | Come si applica |
|---|---|---|
| `secrets/` | non sa decifrare SOPS | `./decrypt.sh && kubectl apply -k k8s/secrets && ./encrypt.sh` |
| `manual/` | non esegue `envsubst` | `./apply-manual.sh` |

Tutto il resto è GitOps.

### Perché `manual/` esiste

Il driver SMB vuole il `source` dentro `volumeAttributes` e un Ingress vuole l'host scritto in
chiaro: **nessuno dei due può arrivare da un `secretKeyRef`**. Se quei due manifest stessero
sotto ArgoCD, l'indirizzo della share e l'hostname pubblico finirebbero in chiaro in un repo
pubblico.

Quindi nel repo restano parametrici, e i valori veri vivono in `.env` (gitignorato), sostituiti
da `apply-manual.sh` al momento dell'apply. Rispetto a cifrarli con SOPS si guadagna che nel
repo restano manifest **leggibili e diffabili**, invece di blocchi `ENC[…]`.

Costa un apply a mano in più. È un costo che si paga quasi mai: un PV è immutabile una volta
creato e l'hostname non cambia.

Il `pre-commit` rifiuta un file di `manual/` che non contenga più segnaposto — cioè che sia
stato committato dopo la sostituzione.

## Prima installazione, in ordine

```bash
# 1. chiave SOPS e hook di protezione
#    la chiave di questo progetto e' gia' generata: serve solo metterla qui
#    (privata in private/age-key.txt, pubblica in public-age-keys.txt)
chmod 600 private/age-key.txt
git config core.hooksPath .githooks

# 2. i valori di questa installazione, che nel repo non entrano
cp .env.dist .env
# ... valorizzare NAS_SHARE e PHOTOVAULT_HOST ...

# 3. i secret, dai modelli
cd k8s/secrets
for f in secrets secrets-pg; do cp $f.yaml.dist $f.yaml; done
# ... valorizzarli (TOKEN: openssl rand -hex 32) ...
cd ../..
./encrypt.sh

# 4. il namespace, che deve esistere prima di tutto il resto
kubectl apply -f k8s/namespace.yaml

# 5. i secret e i manifest parametrici
./decrypt.sh && kubectl apply -k k8s/secrets && ./encrypt.sh
./apply-manual.sh

# 6. l'applicazione
kubectl apply -k k8s

# 7. lo schema del database (vedi "Migrations")
kubectl -n photovault port-forward deployment/postgres 5432:5432
cd ../photovault-db && node app.js -e local up

# 8. ArgoCD, una volta sola
kubectl apply -f k8s/argocd.yaml
```

L'ordine conta in due punti. Il namespace prima di tutto: `apply-manual.sh` si rifiuta di
partire senza, perché creerebbe i due PV (cluster-scoped) e poi fallirebbe su PVC e Ingress,
lasciando il lavoro a metà. E il passo 5 prima del 6: senza `photovault-pgcreds` Postgres non
parte, senza i PVC l'API e i cron restano `Pending`.

`apply-manual.sh` fa da solo un giro di `--dry-run=server` prima dell'apply vero: meglio
scoprire un valore sbagliato subito che con metà risorse già create.

`argocd.yaml` sta fuori dalla kustomization per evitare un riferimento circolare: monitora e
aggiorna proprio quella cartella, e includerlo creerebbe un ciclo.

## Cosa non entra nel repo

Tre meccanismi, e un `pre-commit` che li fa rispettare.

| Dato | Dove vive | Come arriva sul cluster |
|---|---|---|
| share, hostname | `.env` (gitignorato) | `envsubst` in `apply-manual.sh` |
| TOKEN, credenziali PG | `k8s/secrets/*.yaml` cifrati | SOPS + age |
| chiave privata age | `private/` (gitignorata) | non ci arriva: serve solo a decifrare |

L'hook `pre-commit` fa **tre** controlli, perché nessuno dei tre copre gli altri:

1. rifiuta il commit finché esiste il lock file `decrypted`, cioè fra un `decrypt.sh` e il suo
   `encrypt.sh`;
2. rifiuta un file di `k8s/secrets/` che non contenga `ENC[AES256_GCM` — è il caso di un file
   appena copiato da un `.dist` e mai passato per `decrypt.sh`, che il lock non intercetta;
3. rifiuta un file di `k8s/manual/` che non contenga più segnaposto `${…}`, cioè committato
   dopo la sostituzione.

Il filtro è `--diff-filter=ACMR`: senza la `R` un file **rinominato** sfugge a tutti e tre.

Per attivarlo, una volta per clone:

```bash
git config core.hooksPath .githooks
```

## Storage

### Share dei media

Via il driver `smb.csi.k8s.io`. **PV e PVC statici**, con `storageClassName: ""` e `volumeName`
esplicito: il provisioning dinamico non funziona su una share in sola lettura, perché il driver
CSI deve creare una sottodirectory al momento del provision.

Il secret con le credenziali CIFS (`nascreds-ro` / `nascreds-rw`) vive nel namespace `default`
ed è già creato: i PV sono cluster-scoped, quindi il riferimento cross-namespace è legittimo.

**Due PV sulla stessa share**, non uno:

| PV | Access | mountOptions | Montato da |
|---|---|---|---|
| `pv-photos-nas-ro` | ReadOnlyMany | standard + `ro`, `soft`, `timeo=30`, `actimeo=60` | api, dedup, label |
| `pv-photos-nas-rw` | ReadWriteMany | standard (hard mount) | scan |

Il motivo è che CIFS di default monta **hard**: le syscall si bloccano all'infinito invece di
restituire EIO. Un riavvio del NAS bloccherebbe il threadpool dell'API e porterebbe giù anche
`/api/browse`, che tocca soltanto Postgres. Con `soft` sul percorso di lettura, un NAS
irraggiungibile diventa un EIO che la UI mostra come icona rotta.

Sul percorso di **scrittura** `soft` rischierebbe write parziali silenziose, quindi lo scan
tiene il mount hard.

Opzioni comuni: `dir_mode`, `file_mode`, `uid=1000`, `gid=1000` (gli stessi del `runAsUser` dei
pod), `noperm`, `mfsymlinks`, `cache=strict`, **`noserverino`**.

Due conseguenze di `noserverino` e `mfsymlinks` da tenere a mente:
- gli inode sono generati dal client e non sono stabili tra un rimount e l'altro: **non si può
  usare `st_ino` come identità**. L'identità di un file è `(percorso cartella, nome file)`;
- i symlink sono emulati come file da 1067 byte che iniziano con `IntxLNK`. Non si seguono; la
  allowlist di estensioni li scarta comunque.

I PV hanno `persistentVolumeReclaimPolicy: Retain`, quindi per riassociarli serve:

```bash
kubectl patch pv pv-photos-nas-ro --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
```

### Postgres

`postgres:14` (pinnata, stessa versione dello sviluppo), su un PV `hostPath` in
`/var/mnt/hdd-data-1/photovault-postgres` con `storageClassName: manual`. SMB non è un posto
sicuro per i file di un database: il volume locale del nodo sì.

`bit_count()` è core dalla 14 in poi: è il presupposto della scelta `dhash bit(64)` nel dedup, e
il motivo per cui non serve nessuna estensione.

Serve l'initContainer `fix-permissions` (busybox, `chown -R 999:999`) prima dell'avvio: la
directory hostPath appartiene a root e su Talos non c'è SSH per fare il chown sul nodo. Poi il
container gira con `runAsUser: 999`.

`strategy: Recreate` e non RollingUpdate: il PV è ReadWriteMany, ma `PGDATA` non lo è. Con un
rolling update il pod nuovo monterebbe la stessa directory del vecchio prima che questo esca.

## Ingress

`ingressClassName: traefik`, annotazione `cert-manager.io/cluster-issuer: letsencrypt`.
`/` va a `ui-svc`, `/api` va a `api-svc`; la UI chiama `/api` con un percorso relativo, quindi
non esiste nessun problema di CORS in produzione.

Nessun record DNS da creare: il dominio wildcard è già risolto da CoreDNS per i client
Tailscale e da Pi-hole per quelli in LAN.

## I due CronJob dello scan

Non è una duplicazione: sono due compiti diversi con la stessa immagine.

| CronJob | Schedule | `ENQUEUE_ON_START` | A cosa serve |
|---|---|---|---|
| `photovault-scan-queue` | `7,22,37,52 * * * *` | *(vuoto)* | svuota la coda: `trashapply` accodato dall'API quando l'utente risolve un gruppo di duplicati, e le scansioni chieste dalla UI |
| `photovault-scan-nightly` | `0 2 * * *` | `scan,trashpurge` | la scansione vera e la pulizia del cestino scaduto |

Senza il primo, cestinare una foto dalla UI resterebbe senza effetto visibile fino alla notte
successiva. Senza il secondo, nessuno accoderebbe mai una scansione: **su Kubernetes la
schedulazione la fa il CronJob**, e il pod si limita a mettere in coda il lavoro quando viene
svegliato. L'accodamento è idempotente (l'API tiene un solo job `pending` per nome).

Gli orari del primo sono sfalsati apposta dal minuto 0, così non si sovrappone alla scansione
notturna.

`photovault-label` è presente ma **sospeso**: l'immagine non esiste ancora (fase 5). Il
manifest sta lì già completo perché i suoi limiti di memoria fanno parte del bilancio del nodo.

## Vincoli del nodo

Il nodo ha **8 vCPU e 6,7 GB di RAM**, con 1430Mi di requests e 3516Mi di limits già impegnati
da altri servizi. A photovault restano circa **3 GB reali**.

Quindi, a differenza di reimagined-disco, qui le `resources` si mettono davvero:

| Componente | requests | limits |
|---|---|---|
| api | cpu 50m, mem 128Mi | cpu 1, mem 384Mi |
| ui | cpu 10m, mem 32Mi | cpu 200m, mem 128Mi |
| postgres | cpu 100m, mem 192Mi | cpu 2, mem 768Mi |
| scan (×2 CronJob) | cpu 100m, mem 128Mi | cpu 2, mem 1Gi |
| dedup | cpu 100m, mem 96Mi | cpu 1, mem 512Mi |
| label | cpu 250m, mem 512Mi | cpu 2, mem 1Gi |

Le requests dei servizi sempre accesi sommano a 160m di CPU e 352Mi di memoria: il resto è
capienza per i cron, che girano uno alla volta.

`GOMEMLIMIT` sui pod Go è **obbligatorio** e va tenuto sotto al `limits.memory`: il GC di Go non
conosce i limiti cgroup e cresce oltre il limite del pod finché non viene OOMKillato a metà
lavoro. Un'immagine da 24 MP decodificata in RGBA occupa 96 MB.

I CronJob sono **sfalsati** (`scan` a 02:00, `label` a 03:30, `dedup` la domenica alle 05:00)
con `concurrencyPolicy: Forbid`: su un nodo da 7 GB un OOM a livello di nodo porta giù il
cluster intero, non un solo pod.

## Sicurezza dei pod

Livello pod: `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000`.
Livello container: `allowPrivilegeEscalation: false`, `runAsNonRoot: true`,
`capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`. `TZ: "Europe/Rome"` ovunque.

Unica eccezione: l'initContainer `fix-permissions` di Postgres, che deve girare da root per
fare il chown della directory hostPath.

Nessun NetworkPolicy: **l'unica regola di sicurezza dell'applicazione è il bearer token su
`/api/internal/*`**. Tutto il resto è aperto, perché photovault è raggiungibile solo da LAN e
Tailscale. Se un domani venisse esposto fuori, va aggiunta l'autenticazione prima di qualsiasi
altra cosa — e prima ancora va verificato che sul router non ci sia un port forward verso
Traefik, perché quel singolo fatto è l'intera giustificazione dell'assenza di login.

## CI/CD

I tag immagine sono committati come segnaposto `:v0`; quelli veri li scrive la GitHub Action di
ciascun repo componente con `kustomize edit set image`, e ArgoCD (`prune: true`,
`selfHeal: false`) sincronizza.

Perché funzioni servono, su **ogni repo componente**:
- variabile `DOCKERHUB_USERNAME` (Actions → Variables);
- segreti `DOCKERHUB_TOKEN` e `K8S_REPO_TOKEN` (un PAT con permesso di push su questo repo).

Il rilascio è quindi: `git tag v0.1.0 && git push --tags`.

## Migrations

Si lanciano dal PC di sviluppo attraverso un port-forward:

```bash
kubectl -n photovault port-forward deployment/postgres 5432:5432
cd ../photovault-db && node app.js -e local up
```

Il `.env` di `photovault-db` va valorizzato con le stesse credenziali del secret
`photovault-pgcreds`.

## Comandi utili

```bash
kubectl -n photovault get pods,cronjobs,pvc
kubectl -n photovault logs -f deployment/api

# scansione a comando, senza aspettare le 02:00
kubectl -n photovault create job --from=cronjob/photovault-scan-nightly scan-manual
kubectl -n photovault logs -f job/scan-manual

# verifica dei manifest prima di committare
kubectl kustomize k8s | kubectl apply --dry-run=server -f -
```
