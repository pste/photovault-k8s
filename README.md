# photovault-k8s

Manifest Kubernetes per il deploy di photovault sul cluster di casa (TalosOS a nodo singolo).

Kustomize piatto, senza base/overlay e senza Helm, come `reimagined-disco-k8s`.

## Struttura

```
k8s/
├── kustomization.yaml    # resources + blocco images: (i tag reali li scrive la CI)
├── argocd.yaml           # Application — FUORI dalla kustomization, applicata a mano una volta
├── namespace.yaml
├── storage.yaml          # due PV+PVC SMB (ro e rw) sulla share Photos
├── postgres.yaml         # PV hostPath + PVC + Deployment + Service
├── ingress.yaml          # ui-svc + api-svc + Ingress
├── ui.yaml
├── api.yaml
├── cronjob-scan.yaml
├── cronjob-label.yaml
├── cronjob-dedup.yaml
└── secrets/              # SOPS+age, applicati a mano, esclusi dal path di ArgoCD
    ├── kustomization.yaml
    ├── secrets.yaml      # TOKEN
    └── secrets-pg.yaml   # PGDATABASE / PGUSER / PGPASSWORD
```

## Apply

L'applicazione:

```bash
kubectl apply -k k8s
```

I secrets (separati apposta, così ArgoCD gestisce l'app senza conoscere alcun segreto):

```bash
./decrypt.sh
kubectl apply -k k8s/secrets
./encrypt.sh
```

L'Application di ArgoCD, una volta sola:

```bash
kubectl apply -f k8s/argocd.yaml
```

Sta fuori dalla kustomization per evitare un riferimento circolare: monitora e aggiorna
proprio quel file, e includerla creerebbe un ciclo.

## Secrets

SOPS + age.

```bash
age-keygen -o private/age-key.txt
echo '<chiave pubblica>' > public-age-keys.txt
git config core.hooksPath .githooks    # attiva l'hook che blocca il commit in chiaro
```

La chiave privata sta in `private/` (gitignorata), quella pubblica in `public-age-keys.txt`.
L'hook `pre-commit` impedisce di committare i secrets decifrati.

## Storage

### Share dei media

`//SERVERNAS/Photos`, via il driver `smb.csi.k8s.io`. **PV e PVC statici**, con
`storageClassName: ""` e `volumeName` esplicito: non si usa la StorageClass `nas-rw` perché il
suo `source` è legato alla share Music.

Il segreto `nascreds-rw` vive nel namespace `default` ed è creato a mano; i PV sono
cluster-scoped, quindi il riferimento cross-namespace è legittimo.

**Due PV sulla stessa share**, non uno:

| PV | Access | mountOptions | Montato da |
|---|---|---|---|
| `pv-photos-nas-ro` | ReadOnlyMany | standard + `ro`, `soft`, `timeo=30`, `actimeo=60` | api, label, dedup |
| `pv-photos-nas-rw` | ReadWriteMany | standard (hard mount) | scan |

Il motivo è che CIFS di default monta **hard**: le syscall si bloccano all'infinito invece di
restituire EIO. Un riavvio del NAS bloccherebbe il threadpool dell'API e porterebbe giù anche
`/api/browse`, che tocca soltanto Postgres. Con `soft` sul percorso di lettura, un NAS
irraggiungibile diventa un EIO che la UI mostra come icona rotta.

Sul percorso di **scrittura** `soft` rischierebbe write parziali silenziose, quindi lo scan
tiene il mount hard.

Opzioni comuni da rispettare: `dir_mode=0755`, `file_mode=0644`, `uid=1001`, `gid=1001`,
`noperm`, `mfsymlinks`, `cache=strict`, **`noserverino`**.

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

`postgres:14` (pinnata), su un PV `hostPath` in `/var/mnt/hdd-data-1/photovault-postgres` con
`storageClassName: manual`. SMB non è un posto sicuro per i file di un database: il volume
locale del nodo sì.

Serve l'initContainer `fix-permissions` (busybox, `chown -R 999:999`) prima dell'avvio: la
directory hostPath appartiene a root e su Talos non c'è SSH per fare il chown sul nodo. Poi il
container gira con `runAsUser: 999`.

## Ingress

`ingressClassName: traefik`  
annotazione `cert-manager.io/cluster-issuer: letsencrypt`  
`/` va a `ui-svc`, `/api` va a `api-svc`.

Nessun record DNS da creare: il dominio wildcard è già risolto da CoreDNS per i client
Tailscale e da Pi-hole per quelli in LAN.

## Vincoli del nodo

Il nodo ha **8 vCPU e 6,7 GB di RAM**, con 1430Mi di requests e 3516Mi di limits già
impegnati da altri servizi / applicazioni. A photovault restano circa **3 GB reali**.

Quindi, a differenza di reimagined-disco, qui le `resources` si mettono davvero:

| Componente | requests | limits |
|---|---|---|
| api | cpu 100m, mem 256Mi | mem 512Mi |
| ui | cpu 50m, mem 64Mi | mem 128Mi |
| postgres | cpu 250m, mem 512Mi | mem 1Gi |
| scan | cpu 500m, mem 512Mi | cpu 3000m, mem 1Gi |
| label | cpu 500m, mem 800Mi | cpu 2000m, mem 1500Mi |
| dedup | cpu 500m, mem 256Mi | cpu 2000m, mem 512Mi |

I CronJob vanno **sfalsati** (`scan` a `:00`, `label` a `:30`, `dedup` in un altro orario
ancora) con `concurrencyPolicy: Forbid`: su un nodo da 7 GB un OOM a livello di nodo porta giù
il cluster intero, non un solo pod.

## Sicurezza dei pod

Livello pod: `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000`.
Livello container: `allowPrivilegeEscalation: false`, `runAsNonRoot: true`,
`capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`. `TZ: "Europe/Rome"` ovunque.

## CI/CD

I tag immagine sono committati come segnaposto `:v0`; quelli veri li scrive la GitHub Action
di ciascun repo componente con `kustomize edit set image`, e ArgoCD (`prune: true`,
`selfHeal: false`) sincronizza.

## Migrations

Si lanciano dal PC di sviluppo attraverso un port-forward:

```bash
kubectl -n photovault port-forward deployment/postgres 5432:5432
cd ../photovault-db && node app.js -e local up
```

## Comandi utili

```bash
kubectl -n photovault get pods,cronjobs,pvc
kubectl -n photovault create job --from=cronjob/photovault-scan scan-manual
kubectl -n photovault logs -f job/scan-manual
```
