# strata-salad

Deploy [Strata](https://github.com/Niko1221/Strata) (Qwen3.8-Flash-Next, OpenAI/Anthropic-compatible API) on
[SaladCloud](https://salad.com) RTX 3090 container groups.

This repo packages three things:

| File | Rôle |
| --- | --- |
| `salad.sh` | CLI REST SaladCloud : build/push de l'image, création/MAJ/démarrage du container group, statut, logs, suppression. |
| `salad-container-init.sh` | Commande du container (Salad écrase l'`ENTRYPOINT`) : pose les defaults, tente `ulimit -l`, puis `exec` l'entrypoint Strata. |
| `Dockerfile.baked` | Variante « modèle baké » : le modèle est téléchargé **pendant le build**, donc aucun download au démarrage. |
| `.github/workflows/build.yml` | Build sur runner **x86_64** + push vers GHCR. |

## Pourquoi une image bakée ?

Le disque des instances SaladCloud est **éphémère** : sans bake, les ~40–70 Go du modèle sont
re-téléchargés à chaque nouvelle instance, et une instance peut être réallouée à tout moment.
L'image bakée embarque le modèle déjà préparé (pack d'experts + couche MTP comprises) ; le premier
démarrage ne fait que charger le modèle et servir.

> ⚠️ L'image bakée pèse plusieurs dizaines de Go dans **une seule couche**. Les registries avec une
> limite par couche (Docker Hub, GHCR ≈ 10 Go) peuvent refuser le push. Utilisez un registry qui
> accepte les grosses couches (AWS ECR, Azure ACR, Artifact Registry) ou un petit modèle (Q2_0).

### Où builder / où pousser (baked)

Deux contraintes :

0. **Un GPU NVIDIA doit être visible au build.** `setup.py --setup` fait un check matériel au step 1
   (`nvidia-smi`) et refuse sans GPU. Conséquence : le bake ne peut **pas** se faire sur un runner
   GitHub hébergé (ni large — indisponible pour un repo perso). Il faut un builder **avec GPU** :
   container Salad RTX 3090 (le GPU est visible → `setup.py` passe), VM GPU cloud avec Docker, ou ta
   machine avec un driver NVIDIA.
1. **Builder sur x86_64** (l'engine compile du code CPU natif) avec **~250 Go de disque libre**
   (modèle ~68 Go + pack ~36 Go + MTP + couches Docker). Options : VM cloud x86_64 CPU-only,
   runner GitHub self-hosted / larger-runner (le runner hébergé standard n'a pas le disque et le
   build+push peut dépasser les 6 h), ou ta machine x86_64.
2. **Pousser vers un registry sans limite de couche** (self-hosted `registry:2`, AWS ECR, Azure
   ACR, Artifact Registry) : la donnée du modèle est une couche unique de plusieurs dizaines de Go.

```sh
# machine x86_64, ~250 Go libres
export SALAD_IMAGE=registry.example.com/strata:IQ2_XS-baked
SALAD_BAKE=1 STRATA_MODEL=IQ2_XS ./salad.sh build   # base engine (arch 86) puis Dockerfile.baked
./salad.sh push

# image plus légère : jeter les GGUF bruts (LOW_RAM=on lit le pack) — expérimental
SALAD_BAKE=1 SALAD_KEEP_GGUF=0 STRATA_MODEL=IQ2_XS ./salad.sh build

# déploiement (données déjà dans l'image -> aucun download)
SALAD_IMAGE=registry.example.com/strata:IQ2_XS-baked ./salad.sh deploy
```

`image_caching: true` (déjà dans le body) garde les couches en cache sur un nœud : les instances
suivantes **sur ce nœud** démarrent sans re-pull ; une réalocation sur un **nouveau** nœud re-pull
l'image entière.

### B′ — bake sur Salad sans daemon Docker (crane)

Comme `setup.py --setup` exige un GPU visible, on prépare **dans un container Salad RTX 3090**
(le GPU est là), puis on empile les données préparées comme couche via **crane** (binaire statique,
pas de Docker) et on push :

```sh
# PAT GitHub avec le scope write:packages (ou: gh auth refresh -s write:packages)
export SALAD_IMAGE=ghcr.io/<user>/strata-salad:IQ2_XS          # image engine de base
export SALAD_TARGET_IMAGE=ghcr.io/<user>/strata-salad:IQ2_XS-baked
export SALAD_REGISTRY_USER=<user>
export SALAD_REGISTRY_PASS=<PAT_write:packages>

./salad.sh bake                     # crée un group GPU 16 vCPU / 60 Go / 250 Go, prépare + push
./salad.sh logs strata-bake         # suivre
./salad.sh delete strata-bake       # nettoyer quand c'est fini

# déploiement de l'image bakée (aucun download)
SALAD_IMAGE=ghcr.io/<user>/strata-salad:IQ2_XS-baked \
SALAD_DATA_DIR=/opt/strata-data ./salad.sh deploy
```

Le tar des données est **streamé** (FIFO) vers crane → pas de double copie disque. La couche produite
reste grosse (~100 Go, modèle + pack + MTP) : **GHCR peut la refuser** ; dans ce cas, repli sur un
`registry:2` self-hosted / ACR / ECR.

## Prérequis

- `bash`, `curl`, `jq`, `docker`.
- Un compte SaladCloud + une organisation et un projet (`SALAD_ORG`, `SALAD_PROJECT`).
- Une image poussée dans un registry lisible par Salad (GHCR/Docker Hub/ECR…).

## Quickstart

```sh
export SALAD_API_KEY=...        # clé API SaladCloud
export SALAD_ORG=mon-org
export SALAD_PROJECT=mon-projet
export SALAD_IMAGE=ghcr.io/<user>/strata-salad:IQ2_XS

./salad.sh gpu-classes           # vérifier l'UUID de la classe « RTX 3090 »
./salad.sh build                 # construire l'image (NON bakée)
./salad.sh push
./salad.sh deploy                # créer/MAJ + démarrer le container group
./salad.sh status                # état + URL de la gateway
```

Image bakée (recommandé sur Salad) :

```sh
SALAD_BAKE=1 STRATA_MODEL=IQ2_XS ./salad.sh build
./salad.sh push
./salad.sh deploy
```

## Mode runtime (aucun registry à alimenter)

Alternative : ne rien builder/pousser, et laisser le container installer Strata **au démarrage**
depuis une image publique générique (`nvidia/cuda:13.0.0-devel-ubuntu24.04`) :

```sh
export SALAD_IMAGE=nvidia/cuda:13.0.0-devel-ubuntu24.04   # image publique, pas de push
SALAD_RUNTIME_BUILD=1 ./salad.sh deploy
```

`salad-runtime-init.sh` fait alors dans le container : `apt` deps → `git clone` Strata → venv +
pip → `setup.py --setup --yes` (engine pré-compilé pour RTX 30/40/50, sinon compilation) →
téléchargement du modèle → serveur.

| | `SALAD_BAKE=1` (bakée) | `SALAD_RUNTIME_BUILD=1` | image CI (non bakée) |
| --- | --- | --- | --- |
| Build x86_64 requis | oui | non | oui |
| Registry à alimenter | oui (gros) | non | oui (petit) |
| Modèle au 1er démarrage | déjà dedans | re-téléchargé | re-téléchargé |
| Coût par nouvelle instance | faible (pull image) | élevé (apt+pip+engine+70 Go) | élevé (70 Go) |

> Le disque Salad est **éphémère** : en mode runtime, tout est refait à chaque nouvelle instance.
> À réserver au test.

## Modèle et ressources (défauts RTX 3090)

| Réglage | Défaut | Note |
| --- | --- | --- |
| `STRATA_FAMILY` | `qwen` | `qwen` \| `swift` \| `coder` \| `unsloth` |
| `STRATA_MODEL` | `IQ2_XS` | `IQ2_XS` \| `Q2_0` \| `IQ3_XXS` \| `IQ3_S` |
| `STRATA_CONTEXT` | `32768` | |
| `STRATA_VISION` | `no` | `no` \| `cpu` \| `yes` |
| `STRATA_LOW_RAM` | `on` | voir « Pourquoi LOW_RAM=on » ci-dessous |
| `SALAD_CPU` | `8` | vCPU ; **max 16** côté API |
| `SALAD_MEMORY_MB` | `61440` | 60 Go ; **max ~61440 Mo** côté API |
| `SALAD_STORAGE_GB` | `120` | disque éphémère |
| `SALAD_PRIORITY` | `high` | `high` \| `medium` \| `low` \| `batch` |
| `SALAD_NET_AUTH` | `true` | auth par clé API Salad sur la gateway |

Un 3090 (24 Go de VRAM) tient Q2_0 et IQ2_XS ; les tailles IQ3 demandent plus de RAM/VRAM.
Toutes les variables sont listées en tête de `salad.sh`.

### Pourquoi LOW_RAM=on ?

`setup.py` lit la RAM disponible dans **`/proc/meminfo`, soit la RAM du nœud entier**, pas la limite
du container (Salad plafonne l'instance à ~60 Go). Sans `LOW_RAM`, setup croit disposer de 64-128 Go
et prévoit de charger 39-48 Go d'experts **en RAM** (+ verrouillage pour le GPU) : sous le plafond du
container, ça part en OOM/thrash. `LOW_RAM=on` fait lire les experts depuis le **pack sur disque**
(`experts.bin`) au lieu de tout garder résident → empreinte RAM faible, tient dans le plafond.

Conséquence : le décodage est un peu plus lent (lectures disque), mais avec 24 Go de VRAM le cache
d'experts GPU absorbe le plus chaud. **Plus de vCPU (jusqu'à 16) accélère la part CPU** du chemin
low-RAM. Si ton organisation permettait >60 Go de RAM, on pourrait passer `LOW_RAM=off` (experts
résidents → plus rapide) ; au plafond documenté de 60 Go, garde `on`.

## CI (GitHub Actions)

`build.yml` construit l'image sur un runner **x86_64** (obligatoire : l'engine Strata compile du
code CPU natif AVX2/AVX-512) et pousse vers GHCR.

- Déclenchement manuel : *Actions → build-strata-image → Run workflow*. Choisir `bake` et le modèle.
- `bake=true` exige **≥ 180 Go de disque** : les runners GitHub hébergés n'en ont pas assez, passez
  un label de runner self-hosted via l'input `runner`.

## Construire en local

Le code CPU de l'engine est compilé pour la machine qui build. Depuis un Mac ARM, un build
`linux/amd64` via QEMU produira une image probablement inutilisable sur les nœuds Salad :
`salad.sh build` refuse tant que `SALAD_ALLOW_QEMU=1` n'est pas posé. **Buildez sur x86_64.**

## Limitations connues

- **La gateway/probe SaladCloud communique en IPv6.** Strata bind `0.0.0.0` (IPv4 seul), donc sans
  relais la `readiness_probe` ne passe **jamais** : le serveur tourne (logs `ready: …`) mais la
  gateway renvoie un 503 « SaladCloud » et l'instance reste `ready=False`. Les deux scripts d'init
  installent et lancent `socat TCP6-LISTEN:$PORT,ipv6only=1,fork TCP4:127.0.0.1:$PORT` pour ça.
  (Alternative : faire binder Strata sur `::`.)
- **RAM max 60 Go** par instance → `LOW_RAM=on` par défaut.
- **`ulimit memlock` non exposable** par Salad (pas d'équivalent `--ulimit` de `docker run`) :
  `salad-container-init.sh` tente de lever la limite, sinon plus de page faults au chargement.
- **Disque éphémère** : voir « image bakée » ci-dessus.
- **Cold start > fenêtre des probes.** Sur l'image **non bakée**, le 1er démarrage télécharge
  ~40–80 Go (~90–110 min à ~12 Mo/s sur un nœud commun). La fenêtre max d'un probe est **60 min** :
  le `startup_probe` ferait alors **redémarrer** le container, et le disque éphémère perdrait le
  téléchargement (boucle). Déployez donc sans startup ni liveness :
  `SALAD_STARTUP_PROBE=0 SALAD_LIVENESS_PROBE=0 ./salad.sh deploy` (la `readiness_probe` seule ne
  tue jamais). Idéalement, utilisez l'**image bakée** : plus de download, fenêtre 60 min largement
  suffisante.
- **Toute modification du container group recrée l'instance** : comme le disque est éphémère, un
  `update`/PATCH en plein téléchargement repart de zéro. Configurez tout **avant** de démarrer.
- **`networking` non modifiable après création** (sauf `port`) : `auth`, `load_balancer` et les
  timeouts se fixent à la création, sinon il faut recréer le group.
- La clé API du serveur Strata est générée par `salad.sh` (ou `STRATA_API_KEY`). La gateway Salad
  peut en plus exiger la clé API Salad (`SALAD_NET_AUTH=true`).

## Crédits

Strata est un projet de [Niko1221](https://github.com/Niko1221/Strata) (MIT). Ce dépôt ne fait que
l'empaqueter pour SaladCloud.
