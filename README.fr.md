# strata-salad

[English](README.md) | [Français](README.fr.md)

Deploy [Strata](https://github.com/Niko1221/Strata) (Qwen3.8-Flash-Next, OpenAI/Anthropic-compatible API) on
[SaladCloud](https://salad.com) RTX 3090 container groups.

This repo packages four things:

| File | Rôle |
| --- | --- |
| `salad.sh` | CLI REST SaladCloud : build/push, deploy/update/start/stop/status/logs/recreate/delete |
| `salad-container-init.sh` | Commande du container (Salad écrase l'`ENTRYPOINT`) : defaults, `socat` IPv6→IPv4, `exec` l'entrypoint Strata |
| `salad-runtime-init.sh` | Variante « install au démarrage » depuis une image générique (aucun registry) |
| `.github/workflows/build.yml` | Build de l'image engine sur runner **x86_64** + push GHCR |

## Comment ça marche

L'image déployée ne contient **que l'engine** Strata (compilée pour x86_64, CUDA arch 86). Le modèle
(~40–70 Go) est **téléchargé au démarrage** du container, dans le disque éphémère de l'instance.

`image_caching: true` (posé par `salad.sh`) garde l'image engine en cache sur un nœud : les instances
suivantes **sur ce nœud** ne re-pullent pas l'image ; une réallocation sur un **nouveau** nœud la
re-télécharge.

> **Pas d'image « bakée » (modèle embarqué dans l'image) : testé et abandonné.** L'image bakée
> (~100 Go en une seule couche) échoue systématiquement au démarrage sur SaladCloud
> (`Instance Start Failure: Other`), même avec 250 Go de disque et recréation de l'instance ;
> l'image non bakée démarre sans problème avec la même configuration. Tout le code de bake
> (`Dockerfile.baked`, bake API B′, bake terminal Portail B″) a été retiré du dépôt.

## Prérequis

- `bash`, `curl`, `jq`, `docker`.
- Un compte SaladCloud + une organisation et un projet (`SALAD_ORG`, `SALAD_PROJECT`).
- Une image poussée dans un registry lisible par Salad (GHCR/Docker Hub/ECR…).

## Quickstart

1. **Builder l'image engine** (x86_64 obligatoire, voir « Construire en local ») : via GitHub
   Actions (*Actions → build-strata-image → Run workflow*), ou sur une machine x86_64 :

   ```sh
   export SALAD_IMAGE=ghcr.io/<user>/strata-salad:IQ2_XS
   ./salad.sh build && ./salad.sh push
   ```

2. **Déployer** (probes startup/liveness désactivés, voir ci-dessous) :

   ```sh
   export SALAD_API_KEY=...        # clé API SaladCloud
   export SALAD_ORG=mon-org
   export SALAD_PROJECT=mon-projet
   export SALAD_IMAGE=ghcr.io/<user>/strata-salad:IQ2_XS

   ./salad.sh gpu-classes          # vérifier l'UUID de la classe « RTX 3090 »
   SALAD_STARTUP_PROBE=0 SALAD_LIVENESS_PROBE=0 ./salad.sh deploy
   ./salad.sh status               # état + URL de la gateway
   ```

**Pourquoi désactiver les probes startup/liveness ?** Le 1er démarrage télécharge ~40–80 Go
(~90–110 min à ~12 Mo/s sur un nœud commun). La fenêtre max d'un probe est **60 min** : le
`startup_probe` ferait **redémarrer** le container avant la fin du téléchargement, et le disque
éphémère perdrait le téléchargement (boucle sans fin). La `readiness_probe` seule ne tue jamais :
elle gate juste le trafic tant que le modèle n'est pas prêt.

## Commandes

```sh
./salad.sh list                 # tous les container groups (nom, état, URL)
./salad.sh deploy [NAME]        # créer/MAJ + démarrer
./salad.sh update [NAME]        # modifier la config (PATCH, sans démarrer)
./salad.sh start [NAME]         # démarrer
./salad.sh stop  [NAME]         # arrêter
./salad.sh restart [NAME]       # stop puis start
./salad.sh start-all            # démarrer tous les groups du projet
./salad.sh stop-all             # arrêter tous les groups du projet
./salad.sh status [NAME]        # état + URL + instances
./salad.sh logs   [NAME]        # logs système
./salad.sh recreate [NAME]      # appliquer la version courante SANS re-pull d'image
./salad.sh delete [NAME]        # supprimer (irréversible, force un re-pull ensuite)
```

- `update` (PATCH) reprend par défaut l'image/ressources/modèle **actuels** du group : seuls les
  champs surchargés changent (via env `SALAD_*`/`STRATA_*`).
- **Pour appliquer un PATCH sans rebuild/re-pull** : `update` puis `recreate`. L'endpoint Salad
  `recreate` détruit et relance le container **sur le même nœud**, image en cache → pas de
  re-téléchargement. Éviter `delete` (lui force un re-pull).

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

| | image CI (recommandé) | `SALAD_RUNTIME_BUILD=1` |
| --- | --- | --- |
| Build x86_64 requis | oui (une fois, en CI) | non |
| Registry à alimenter | oui (petit : engine seul) | non |
| Coût par nouvelle instance | download du modèle | apt+pip+engine+download du modèle |

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
| `SALAD_CPU` | `8` | vCPU ; **max 16** — mettre **16** est le levier le plus utile en low-RAM |
| `SALAD_MEMORY_MB` | `61440` | 60 Go ; **max ~61440 Mo** côté API |
| `SALAD_STORAGE_GB` | `120` | disque éphémère |
| `SALAD_PRIORITY` | `high` | `high` \| `medium` \| `low` \| `batch` |
| `SALAD_NET_AUTH` | `true` | auth par clé API Salad sur la gateway |
| `STRATA_API_KEY` | (généré) | clé du serveur Strata (injectée aussi comme `STRATA_API_KEY`) |
| `STRATA_ALLOWED_HOSTS` | `auto` | `auto` = gateway de **ce** group ; csv ; `.exemple.com` ; `*` |

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

## Optimisation

### Quel modèle pour un RTX 3090 (24 Go VRAM, 60 Go RAM, 16 vCPU) ?

En low-RAM, c'est le **CPU** qui calcule les experts que le GPU ne garde pas. Donc **plus de vCPU =
décodage plus rapide**, et ça rend les modèles plus lourds supportables.

| Modèle | Télécharg. | RAM | Aire experts | Qualité / vitesse |
| --- | --- | --- | --- | --- |
| `Q2_0` | 66 Go | 48 Go | 34 Go | le plus rapide |
| `IQ2_XS` | 68 Go | 48 Go | 35.5 Go | recommandé (équilibre) |
| `IQ3_XXS` | 76 Go | 60 Go | 43 Go | **meilleure qualité** tenant dans 60 Go, plus lent |
| `IQ3_S` | 84 Go | **62 Go** | 50 Go | meilleure qualité mais **dépasse 60 Go** → à éviter |
| `coder` (IQ1_M) | 58 Go | 32 Go | 23 Go | pour coder, plus rapide ; plus faible hors code |

- **Meilleur modèle réaliste ici : `IQ3_XXS`** (RAM pile au plafond de 60 Go → tendu ; à tester). Sinon
  garder `IQ2_XS`.
- **`IQ3_S` non viable** au plafond 60 Go.
- **Agent de code** : `STRATA_FAMILY=coder` (IQ1_M), rapide et léger, mais plus faible en général.

### Leviers d'optimisation (dans l'ordre)

1. **`SALAD_CPU=16`** : la part CPU du low-RAM en profite directement (gratuit, max API).
2. **`SALAD_MEMORY_MB=61440`** (déjà max) : plus d'experts résidents = moins de lectures disque.
3. **RAM > 60 Go ?** si ton org l'autorise : `STRATA_LOW_RAM=off` → experts résidents, **le plus
   rapide** (mais ~50 Go de RAM résidents).
4. **Contexte** : baisser `STRATA_CONTEXT` (ex. `16384`/`8192`) réduit le KV → plus de place pour le
   cache d'experts GPU → plus rapide. Garder `32768` si les agents ont besoin d'un grand contexte.
5. **`STRATA_KV=k8v4`** (INT8 K, 4-bit V) : KV plus petit en VRAM → plus d'experts sur le GPU.
6. **`SALAD_PRIORITY=high`** : nœuds plus fiables/moins interrompus (coûte plus cher).
7. Après un PATCH, la nouvelle version ne bascule pas toute seule : **`./salad.sh recreate`**.
8. **`--parallel`** reste à 1 par défaut : sur 24 Go, 2 requêtes simultanées ralentissent chacune.
9. **`SALAD_CONVERSATION_CACHE_MIB=8192`** : cache de conversation multi-tours (relances de projets
   longs sans re-lire ~90 % du prompt). Écrit dans la config au setup.

Exemple « qualité max » :
```sh
SALAD_CPU=16 STRATA_MODEL=IQ3_XXS STRATA_CONTEXT=32768 STRATA_KV=k8v4 \
SALAD_STARTUP_PROBE=0 SALAD_LIVENESS_PROBE=0 ./salad.sh deploy
```

## Accès à l'API (gateway Salad + serveur Strata)

Deux couches d'authentification **indépendantes**, chacune avec sa clé :

| Couche | En-tête HTTP | Clé |
| --- | --- | --- |
| Gateway Salad (`SALAD_NET_AUTH=true`) | `Salad-Api-Key` | **clé API SaladCloud** (`SALAD_API_KEY`, portail) |
| Serveur Strata (`api_key`) | `Authorization: Bearer` (champ `apiKey` du client) | **clé Strata** générée par `salad.sh` |

Détail qui piège : le serveur Strata lit **`STRATA_API_KEY`** (pas `API_KEY`, qui ne sert qu'à
`setup.py`). Les scripts d'init propagent `API_KEY → STRATA_API_KEY` pour que la clé posée par
`salad.sh` soit bien utilisée par le serveur.

### DNS rebinding (403 « Host … is not allowed »)

Sans clé serveur, Strata n'accepte que les noms d'hôte connus (protection DNS rebinding). La gateway
Salad relaie les requêtes avec `Host: <group>.salad.cloud`, un nom inconnu du serveur → **403**. Au
déploiement, `salad.sh` résout le hostname exact du group (champ API `networking.dns`) et pose
`STRATA_ALLOWED_HOSTS` avec ce nom. Valeurs acceptées :

- `auto` (défaut) : uniquement la gateway de **ce** container group ;
- liste séparée par des virgules (`strata.example.com,nas.lan`) ; un préfixe point (`.example.com`)
  couvre le domaine et ses sous-domaines ;
- `*` : désactive complètement le contrôle (à éviter).

Avec une clé Strata (`STRATA_API_KEY`), le contrôle est **de toute façon désactivé** : le serveur fait
`if svc.api_key or host_allowed(...)`. L'allowlist ne sert donc qu'en mode sans clé serveur.

### Client OpenAI-compatible

Endpoint : `https://<group>.salad.cloud/v1`, modèle rapporté par `GET /v1/models` (le nom suit
`STRATA_MODEL`, ex. `qwen3.8-flash-next-iq2_xs` ou `qwen3.8-flash-next-iq3_xxs`). Exemple OpenCode
(`~/.config/opencode/opencode.json`) — sans clé serveur, `apiKey` est un dummy et la seule auth est
l'en-tête Salad :

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "saladcloud/qwen3.8-flash-next-iq2_xs",
  "provider": {
    "saladcloud": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Strata",
      "options": {
        "baseURL": "https://<group>.salad.cloud/v1",
        "apiKey": "dummy",
        "headers": { "Salad-Api-Key": "{env:SALAD_API_KEY}" }
      },
      "models": {
        "qwen3.8-flash-next-iq2_xs": {
          "name": "Qwen3.8 Flash Next (IQ2_XS)",
          "limit": { "context": 32768, "output": 8192 }
        }
      }
    }
  }
}
```

Vérifier l'accès :

```sh
curl -H "Salad-Api-Key: $SALAD_API_KEY" "https://<group>.salad.cloud/v1/models"
```

> Si le serveur a une clé Strata (`STRATA_API_KEY`), mettez **cette** clé dans `apiKey` (le client
> l'envoie en `Authorization: Bearer`) et gardez `Salad-Api-Key` pour la gateway.

## CI (GitHub Actions)

`build.yml` construit l'image engine sur un runner **x86_64** (obligatoire : l'engine Strata compile
du code CPU natif AVX2/AVX-512) et la pousse vers GHCR. Déclenchement manuel : *Actions →
build-strata-image → Run workflow* (choix du modèle, de l'arch CUDA et du ref Strata).

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
- **Disque éphémère** : le modèle est re-téléchargé à chaque nouvelle instance ; toute modification
  du container group recrée l'instance (un `update`/PATCH en plein téléchargement repart de zéro) —
  configurez tout **avant** de démarrer.
- **Cold start > fenêtre des probes** : voir « Quickstart » (`SALAD_STARTUP_PROBE=0
  SALAD_LIVENESS_PROBE=0`).
- **Mise à jour = version « pending ».** Un PATCH crée une nouvelle version (`pending_change: true`)
  mais Salad ne remplace pas toujours l'instance toute seule : elle continue de servir l'ancienne
  version. Pour forcer la bascule **sans re-télécharger l'image**, recréer l'instance
  (`./salad.sh recreate`) ; c'est ce qui a été utilisé pour appliquer le fix `allowed_hosts`.
  `salad.sh update` ne démarre pas le group, et un `start` peut relancer l'ancienne version tant que
  la nouvelle est en attente.
- **DNS rebinding / clés API** : voir « Accès à l'API » ci-dessus (403 « Host … is not allowed »,
  `STRATA_ALLOWED_HOSTS`, propagation `API_KEY → STRATA_API_KEY`).
- **`networking` non modifiable après création** (sauf `port`) : `auth`, `load_balancer` et les
  timeouts se fixent à la création, sinon il faut recréer le group.

## Crédits

Strata est un projet de [Niko1221](https://github.com/Niko1221/Strata) (MIT). Ce dépôt ne fait que
l'empaqueter pour SaladCloud.
