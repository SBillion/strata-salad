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
| `STRATA_LOW_RAM` | `on` | Salad plafonne la RAM à 60 Go |
| `SALAD_CPU` | `8` | vCPU |
| `SALAD_MEMORY_MB` | `61440` | 60 Go (max Salad) |
| `SALAD_STORAGE_GB` | `120` | disque éphémère |
| `SALAD_PRIORITY` | `high` | `high` \| `medium` \| `low` \| `batch` |
| `SALAD_NET_AUTH` | `true` | auth par clé API Salad sur la gateway |

Un 3090 (24 Go de VRAM) tient Q2_0 et IQ2_XS ; les tailles IQ3 demandent plus de RAM/VRAM.
Toutes les variables sont listées en tête de `salad.sh`.

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

- **RAM max 60 Go** par instance → `LOW_RAM=on` par défaut.
- **`ulimit memlock` non exposable** par Salad (pas d'équivalent `--ulimit` de `docker run`) :
  `salad-container-init.sh` tente de lever la limite, sinon plus de page faults au chargement.
- **Disque éphémère** : voir « image bakée » ci-dessus.
- La clé API du serveur Strata est générée par `salad.sh` (ou `STRATA_API_KEY`). La gateway Salad
  peut en plus exiger la clé API Salad (`SALAD_NET_AUTH=true`).

## Crédits

Strata est un projet de [Niko1221](https://github.com/Niko1221/Strata) (MIT). Ce dépôt ne fait que
l'empaqueter pour SaladCloud.
