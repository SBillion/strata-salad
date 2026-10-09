#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# salad.sh — CLI SaladCloud (REST API publique) pour déployer Strata
#            (Qwen3.8-Flash-Next) sur un container group RTX 3090.
#
# Dépendances : bash 4+, curl, jq, docker (seulement pour build/push)
#
# Usage : salad.sh <commande> [options]
#   build                 Construire l'image Strata (arch RTX 3090 = 86)
#   push                  Pousser l'image vers le registry
#   gpu-classes           Lister les classes GPU (trouver l'UUID RTX 3090)
#   deploy [--wait]       Créer (ou mettre à jour) + démarrer le container group
#   update                Mettre à jour le container group existant (PATCH)
#   start                 Démarrer le container group
#   stop                  Arrêter le container group
#   status                Afficher l'état, l'URL et les instances
#   logs                  Afficher les logs système du container group
#   delete                Supprimer le container group (irréversible)
#
# Variables d'environnement :
#   SALAD_API_KEY        (requis)  Clé API SaladCloud
#   SALAD_ORG            (requis)  Nom de l'organisation
#   SALAD_PROJECT        (requis)  Nom du projet
#   SALAD_IMAGE          (requis)  Image, ex: docker.io/monuser/strata:3090
#   SALAD_GPU_CLASS      (opt)     Nom de la classe GPU, défaut "RTX 3090"
#   SALAD_GPU_CLASS_ID   (opt)     UUID de la classe GPU (sinon résolu par nom)
#   SALAD_GROUP_NAME     (opt)     Nom DNS du container group, défaut "strata"
#   SALAD_CPU            (opt)     vCPU, défaut 8
#   SALAD_MEMORY_MB      (opt)     RAM en Mo, défaut 61440 (max Salad)
#   SALAD_SHM_MB         (opt)     /dev/shm en Mo, défaut 16384
#   SALAD_STORAGE_GB     (opt)     Disque éphémère en Go, défaut 120
#   SALAD_REPLICAS       (opt)     Réplicas, défaut 1
#   SALAD_PRIORITY       (opt)     high|medium|low|batch, défaut high
#   SALAD_COUNTRY_CODES  (opt)     ex: "fr,de" ; vide = tous pays
#   SALAD_PORT           (opt)     Port HTTP exposé, défaut 8080
#   SALAD_NET_AUTH       (opt)     true|false (auth via clé API Salad), défaut true
#   SALAD_STARTUP_INITIAL_DELAY / SALAD_STARTUP_PERIOD / SALAD_STARTUP_FAILURE
#                                  (opt) fenêtre du startup probe, défauts 60/120/20
#   SALAD_STARTUP_PROBE / SALAD_LIVENESS_PROBE (opt) 0 = ne pas créer ce probe
#   SALAD_LIVENESS_PERIOD / SALAD_LIVENESS_FAILURE (opt) défauts 30/5
#   STRATA_API_KEY       (opt)     Clé du serveur Strata (sinon générée)
#   STRATA_FAMILY        (opt)     qwen|swift|coder|unsloth, défaut qwen
#   STRATA_MODEL         (opt)     IQ2_XS|Q2_0|IQ3_XXS|IQ3_S, défaut IQ2_XS
#   STRATA_CONTEXT       (opt)     Contexte, défaut 32768
#   STRATA_VISION        (opt)     no|yes|cpu, défaut no
#   STRATA_LOW_RAM       (opt)     on|off|auto, défaut on
#   STRATA_KV            (opt)     int8|q4_0|k8v4 (vide = défaut Strata)
#   STRATA_ALLOWED_HOSTS (opt)     noms Host acceptés sans clé API (DNS
#                                  rebinding) ; "auto" (défaut) = le hostname de
#                                  la gateway du container group uniquement
#   SALAD_SOURCE_DIR     (opt)     Clone Strata, défaut ./.strata
#   SALAD_BUILD_PLATFORM (opt)     Plateforme buildx, défaut linux/amd64
#   SALAD_CUDA_ARCH      (opt)     Arch CUDA, défaut 86 (RTX 3090)
#   SALAD_BUILD_VISION   (opt)     1|0, défaut 1
#   SALAD_ALLOW_QEMU     (opt)     1 pour autoriser un build amd64 sous QEMU (Mac)
#   SALAD_BAKE           (opt)     1 = télécharger le modèle AU BUILD (image bakée)
#   SALAD_KEEP_GGUF      (opt)     1 (défaut) | 0 = supprimer les GGUF bruts de
#                                  l'image bakée (~-68 Go ; LOW_RAM=on requis)
#   B' (bake) : SALAD_TARGET_IMAGE (image à produire, sinon <base>:<MODEL>-baked),
#               SALAD_REGISTRY_HOST (ghcr.io), SALAD_REGISTRY_USER, SALAD_REGISTRY_PASS,
#               SALAD_BAKE_GROUP (strata-bake), SALAD_BAKE_CPU (16),
#               SALAD_BAKE_MEMORY_MB (61440), SALAD_BAKE_STORAGE_GB (250)
#   SALAD_RUNTIME_BUILD  (opt)     1 = installer/builder Strata AU DÉMARRAGE du
#                                  container (image générique, aucun registry)
#   SALAD_RUNTIME_IMAGE  (opt)     Image de base pour le runtime build
#                                  (défaut nvidia/cuda:13.0.0-devel-ubuntu24.04)
#   SALAD_DATA_DIR       (opt)     Chemin data Strata dans le container (vide = auto)
# ---------------------------------------------------------------------------

set -euo pipefail

# ===========================================================================
# CONFIG
# ===========================================================================
API_BASE="${SALAD_API_BASE:-https://api.salad.com/api/public}"

ORG="${SALAD_ORG:-}"
PROJECT="${SALAD_PROJECT:-}"
IMAGE="${SALAD_IMAGE:-}"

GPU_CLASS_NAME="${SALAD_GPU_CLASS:-RTX 3090}"
GPU_CLASS_ID="${SALAD_GPU_CLASS_ID:-}"

GROUP_NAME="${SALAD_GROUP_NAME:-strata}"
DISPLAY_NAME="${SALAD_DISPLAY_NAME:-Strata RTX 3090}"

CPU="${SALAD_CPU:-8}"
MEMORY_MB="${SALAD_MEMORY_MB:-61440}"
SHM_MB="${SALAD_SHM_MB:-16384}"
STORAGE_GB="${SALAD_STORAGE_GB:-120}"
REPLICAS="${SALAD_REPLICAS:-1}"
PRIORITY="${SALAD_PRIORITY:-high}"
COUNTRY_CODES="${SALAD_COUNTRY_CODES:-}"
PORT="${SALAD_PORT:-8080}"
NET_AUTH="${SALAD_NET_AUTH:-true}"

# Probes (secondes). Startup = fenêtre maximale pour le 1er téléchargement du
# modèle (~70 Go, image non bakée). bornes API : initial_delay<=1200,
# period<=120, failure_threshold<=20 -> fenêtre max 1200 + 20*120 = 3600s.
# IMPORTANT : sur l'image NON bakée, le cold start (~100 min à ~12 Mo/s,
# IQ2_XS = 2x39 Go) DÉPASSE la fenêtre max de 60 min : le startup probe fait
# alors redémarrer le container et le disque éphémère perd le download.
# -> mettez SALAD_STARTUP_PROBE=0 (et éventuellement SALAD_LIVENESS_PROBE=0).
# La readiness seule ne tue jamais le container.
STARTUP_PROBE="${SALAD_STARTUP_PROBE:-1}"
LIVENESS_PROBE="${SALAD_LIVENESS_PROBE:-1}"
STARTUP_INITIAL_DELAY="${SALAD_STARTUP_INITIAL_DELAY:-1200}"
STARTUP_PERIOD="${SALAD_STARTUP_PERIOD:-120}"
STARTUP_FAILURE="${SALAD_STARTUP_FAILURE:-20}"
LIVENESS_PERIOD="${SALAD_LIVENESS_PERIOD:-30}"
LIVENESS_FAILURE="${SALAD_LIVENESS_FAILURE:-5}"

STRATA_FAMILY="${STRATA_FAMILY:-qwen}"
STRATA_MODEL="${STRATA_MODEL:-IQ2_XS}"
STRATA_CONTEXT="${STRATA_CONTEXT:-32768}"
STRATA_VISION="${STRATA_VISION:-no}"
STRATA_LOW_RAM="${STRATA_LOW_RAM:-on}"
STRATA_KV="${STRATA_KV:-}"
STRATA_API_KEY="${STRATA_API_KEY:-}"
# Noms d'hôte (Host) que le serveur Strata accepte quand il n'a pas de clé API
# (protection DNS rebinding). "auto" (défaut) = uniquement le hostname de la
# gateway de CE container group, résolu via l'API au déploiement. Sinon :
# plusieurs noms séparés par des virgules ; "*" coupe le contrôle,
# ".exemple.com" couvre le domaine et ses sous-domaines.
STRATA_ALLOWED_HOSTS="${STRATA_ALLOWED_HOSTS:-auto}"

STRATA_REPO="${SALAD_STRATA_REPO:-https://github.com/Niko1221/Strata.git}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SALAD_SOURCE_DIR:-$REPO_DIR/.strata}"
BUILD_PLATFORM="${SALAD_BUILD_PLATFORM:-linux/amd64}"
CUDA_ARCH="${SALAD_CUDA_ARCH:-86}"
BUILD_VISION="${SALAD_BUILD_VISION:-1}"

# Modèle baké dans l'image (download au build) : évite les ~70 Go à chaque
# nouvelle instance Salad. 1 = activé, 0 = download au démarrage (défaut).
BAKE="${SALAD_BAKE:-0}"
BAKED_DOCKERFILE="$REPO_DIR/Dockerfile.baked"
# Image bakée : garder les GGUF bruts (1) ou les supprimer (0, ~-68 Go) quand
# LOW_RAM=on lit les experts depuis le pack (expérimental).
KEEP_GGUF="${SALAD_KEEP_GGUF:-1}"

# B' : bake des données préparées dans une image, depuis un container GPU Salad,
# via crane (pas de daemon Docker). Voir salad-bake-init.sh.
BAKE_GROUP="${SALAD_BAKE_GROUP:-strata-bake}"
TARGET_IMAGE="${SALAD_TARGET_IMAGE:-}"
REGISTRY_HOST="${SALAD_REGISTRY_HOST:-ghcr.io}"
REGISTRY_USER="${SALAD_REGISTRY_USER:-}"
REGISTRY_PASS="${SALAD_REGISTRY_PASS:-}"
BAKE_CPU="${SALAD_BAKE_CPU:-16}"
BAKE_MEMORY_MB="${SALAD_BAKE_MEMORY_MB:-61440}"
BAKE_STORAGE_GB="${SALAD_BAKE_STORAGE_GB:-250}"

# Installation + build de Strata AU DÉMARRAGE du container, depuis une image
# générique (aucun registry à alimenter). 1 = activé.
# Coût : tout est refait à chaque instance (disque Salad éphémère).
RUNTIME_BUILD="${SALAD_RUNTIME_BUILD:-0}"

# Chemin des données Strata DANS le container. Vide = on laisse l'image décider
# (/data pour l'image standard, /opt/strata-data pour l'image bakée).
DATA_DIR="${SALAD_DATA_DIR:-}"

if [ "$RUNTIME_BUILD" = "1" ]; then
  INIT_SCRIPT="$REPO_DIR/salad-runtime-init.sh"
  [ -n "$IMAGE" ] || IMAGE="${SALAD_RUNTIME_IMAGE:-nvidia/cuda:13.0.0-devel-ubuntu24.04}"
  [ -n "$DATA_DIR" ] || DATA_DIR="/data"
else
  INIT_SCRIPT="$REPO_DIR/salad-container-init.sh"
fi
BAKE_INIT="$REPO_DIR/salad-bake-init.sh"
LAST_GROUP_FILE="${SALAD_LAST_GROUP_FILE:-$HOME/.salad-strata-group}"

# ===========================================================================
# Utilitaires
# ===========================================================================
err() { echo "ERREUR: $*" >&2; exit 1; }
info() { echo "[salad] $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || err "$1 est requis mais non installé"; }
need curl
need jq

require_org_project() {
  [ -n "$ORG" ] || err "SALAD_ORG est requis"
  [ -n "$PROJECT" ] || err "SALAD_PROJECT est requis"
}

# ---------------------------------------------------------------------------
# api_call <METHOD> <PATH> [JSON_BODY]
# Gère 429 (Retry-After) et 5xx/réseau (backoff exponentiel), comme runpod.sh.
# API_LAST_STATUS / API_LAST_RESPONSE : dernier code HTTP et corps.
# Retour : 0 si 2xx, 1 si 4xx définitif.
# ---------------------------------------------------------------------------
API_LAST_STATUS=""
API_LAST_RESPONSE=""

api_call() {
  local method="$1" path="$2" body="${3:-}"
  local max_attempts=5 attempt=0

  while :; do
    attempt=$((attempt + 1))
    local tmp hdrs http_code ctype="application/json"
    [ "$method" = "PATCH" ] && ctype="application/merge-patch+json"
    tmp=$(mktemp)
    hdrs=$(mktemp)

    http_code=$(curl -sS -X "$method" "$API_BASE$path" \
      -H "Salad-Api-Key: $SALAD_API_KEY" \
      -H "accept: application/json" \
      -H "content-type: $ctype" \
      -o "$tmp" -D "$hdrs" -w '%{http_code}' \
      ${body:+-d "$body"} 2>/dev/null) || http_code="000"

    local http_status="${http_code//[!0-9]/}"
    [ -n "$http_status" ] || http_status="000"

    local response
    response=$(cat "$tmp" 2>/dev/null || true)
    rm -f "$tmp"

    API_LAST_STATUS="$http_status"
    API_LAST_RESPONSE="$response"

    if [[ "$http_status" =~ ^2[0-9]{2}$ ]]; then
      rm -f "$hdrs"; return 0
    fi

    if [ "$http_status" = "429" ]; then
      local retry_after
      retry_after=$(awk 'tolower($1)=="retry-after:"{gsub(/\r/,"",$2);print $2;exit}' "$hdrs")
      rm -f "$hdrs"
      [[ "$retry_after" =~ ^[0-9]+$ ]] || retry_after=5
      [ "$attempt" -ge "$max_attempts" ] && err "Rate limit (429) persistant sur $path"
      info "Rate limit (429), attente ${retry_after}s ($attempt/$max_attempts)"
      sleep "$retry_after"; continue
    fi

    if [[ "$http_status" =~ ^5[0-9]{2}$ ]] || [ "$http_status" = "000" ]; then
      rm -f "$hdrs"
      [ "$attempt" -ge "$max_attempts" ] && err "Échec après $max_attempts tentatives ($http_status) sur $path"
      local delay=$((2 ** attempt))
      info "Erreur transitoire ($http_status), backoff ${delay}s ($attempt/$max_attempts)"
      sleep "$delay"; continue
    fi

    rm -f "$hdrs"; return 1
  done
}

api_detail() { jq -r '.detail // .title // "erreur inconnue"' <<<"$API_LAST_RESPONSE" 2>/dev/null || echo "erreur"; }

save_last_group() { echo "$1" >"$LAST_GROUP_FILE"; info "Dernier container group: $1"; }

get_group_name() {
  if [ -n "${1:-}" ]; then echo "$1"; return; fi
  if [ -f "$LAST_GROUP_FILE" ] && [ -s "$LAST_GROUP_FILE" ]; then cat "$LAST_GROUP_FILE"; return; fi
  echo "$GROUP_NAME"
}

# ---------------------------------------------------------------------------
# resolve_gpu_class_id — trouve l'UUID de la classe GPU via l'API
# ---------------------------------------------------------------------------
resolve_gpu_class_id() {
  [ -n "$GPU_CLASS_ID" ] && return 0
  require_org_project
  info "Résolution de la classe GPU \"$GPU_CLASS_NAME\"..."
  api_call GET "/organizations/$ORG/gpu-classes" || err "Impossible de lister les classes GPU : $(api_detail)"

  GPU_CLASS_ID=$(jq -r --arg n "$GPU_CLASS_NAME" '
    (.items // []) | map(select((.name // "") == $n)) | (.[0].id // empty)
  ' <<<"$API_LAST_RESPONSE")

  if [ -z "$GPU_CLASS_ID" ]; then
    info "Correspondance exacte introuvable, essai partiel..."
    # tri par longueur de nom : "RTX 3090 (24 GB)" avant "RTX 3090 Ti (24 GB)"
    GPU_CLASS_ID=$(jq -r --arg n "$GPU_CLASS_NAME" '
      (.items // [])
      | map(select((.name // "") | ascii_downcase | contains($n | ascii_downcase)))
      | sort_by(.name | length)
      | (.[0].id // empty)
    ' <<<"$API_LAST_RESPONSE")
  fi
  [ -n "$GPU_CLASS_ID" ] || err "Aucune classe GPU ne correspond à \"$GPU_CLASS_NAME\" (voir 'salad.sh gpu-classes')"
  info "  classe GPU id = $GPU_CLASS_ID"
}

# ---------------------------------------------------------------------------
# Construction du body
# ---------------------------------------------------------------------------
build_environment() {
  jq -cn \
    --arg family "$STRATA_FAMILY" \
    --arg model "$STRATA_MODEL" \
    --arg context "$STRATA_CONTEXT" \
    --arg vision "$STRATA_VISION" \
    --arg low_ram "$STRATA_LOW_RAM" \
    --arg kv "$STRATA_KV" \
    --arg port "$PORT" \
    --arg api_key "$STRATA_API_KEY" \
    --arg allowed_hosts "$STRATA_ALLOWED_HOSTS" \
    --arg data_dir "$DATA_DIR" \
    '{
      FAMILY: $family,
      MODEL: $model,
      CONTEXT: $context,
      VISION: $vision,
      LOW_RAM: $low_ram,
      HOST: "0.0.0.0",
      PORT: $port,
      STRATA_EXECV: "1"
    }
    + (if $data_dir      != "" then {STRATA_DATA: $data_dir}               else {} end)
    + (if $kv            != "" then {KV: $kv}                             else {} end)
    + (if $api_key       != "" then {API_KEY: $api_key, STRATA_API_KEY: $api_key} else {} end)
    + (if $allowed_hosts != "" then {STRATA_ALLOWED_HOSTS: $allowed_hosts} else {} end)'
}

build_container() {
  local init_script env resources
  [ -f "$INIT_SCRIPT" ] || err "Le fichier d'init $INIT_SCRIPT est requis"
  init_script=$(cat "$INIT_SCRIPT")
  env=$(build_environment)

  resources=$(jq -cn \
    --argjson cpu "$CPU" \
    --argjson mem "$MEMORY_MB" \
    --argjson shm "$SHM_MB" \
    --argjson storage "$((STORAGE_GB * 1073741824))" \
    --arg gpu_id "$GPU_CLASS_ID" \
    '{cpu: $cpu, memory: $mem, shm_size: $shm, storage_amount: $storage, gpu_classes: [$gpu_id]}')

  # command = ["/bin/sh","-c", <script>] : Salad écrase ENTRYPOINT/CMD.
  jq -cn \
    --arg image "$IMAGE" \
    --arg priority "$PRIORITY" \
    --argjson env "$env" \
    --argjson resources "$resources" \
    --arg script "$init_script" \
    '{
      image: $image,
      resources: $resources,
      command: ["/bin/sh", "-c", $script],
      environment_variables: $env,
      image_caching: true,
      priority: $priority
    }'
}

build_networking() {
  # LLM = connexions longues/streaming : on privilégie least_number_of_connections
  # et les timeouts max (100000 ms = 100 s) plutôt que round_robin.
  jq -cn \
    --argjson port "$PORT" \
    --argjson auth "$NET_AUTH" \
    '{
      protocol: "http",
      auth: $auth,
      port: $port,
      load_balancer: "least_number_of_connections",
      client_request_timeout: 100000,
      server_response_timeout: 100000
    }'
}

# Probes HTTP sur /health du serveur Strata ($PORT). Logique :
# - startup : large fenêtre (le 1er démarrage télécharge ~40-70 Go) ;
# - readiness : gate le trafic tant que le modèle n'est pas prêt ;
# - liveness : ne s'exécute qu'après le startup (sinon il tuerait le chargement).
build_probes() {
  jq -cn \
    --argjson port "$PORT" \
    --argjson s_on "$STARTUP_PROBE" \
    --argjson l_on "$LIVENESS_PROBE" \
    --argjson s_init "$STARTUP_INITIAL_DELAY" \
    --argjson s_period "$STARTUP_PERIOD" \
    --argjson s_fail "$STARTUP_FAILURE" \
    --argjson l_period "$LIVENESS_PERIOD" \
    --argjson l_fail "$LIVENESS_FAILURE" \
    '{ readiness_probe: {
        http: {headers: [], path: "/health", port: $port, scheme: "http"},
        initial_delay_seconds: 10,
        period_seconds: 10,
        failure_threshold: 3,
        success_threshold: 1,
        timeout_seconds: 5
      } }
    + (if $s_on == 1 then { startup_probe: {
        http: {headers: [], path: "/health", port: $port, scheme: "http"},
        initial_delay_seconds: $s_init,
        period_seconds: $s_period,
        failure_threshold: $s_fail,
        success_threshold: 1,
        timeout_seconds: 10
      } } else {} end)
    + (if $l_on == 1 then { liveness_probe: {
        http: {headers: [], path: "/health", port: $port, scheme: "http"},
        initial_delay_seconds: 0,
        period_seconds: $l_period,
        failure_threshold: $l_fail,
        success_threshold: 1,
        timeout_seconds: 10
      } } else {} end)'
}

build_body() {
  local container networking probes codes
  container=$(build_container)
  networking=$(build_networking)
  probes=$(build_probes)

  if [ -n "$COUNTRY_CODES" ]; then
    codes=$(jq -cn --arg csv "$COUNTRY_CODES" \
      '$csv | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')
  else
    codes='null'
  fi

  jq -cn \
    --arg name "$GROUP_NAME" \
    --arg display "$DISPLAY_NAME" \
    --argjson replicas "$REPLICAS" \
    --argjson container "$container" \
    --argjson networking "$networking" \
    --argjson probes "$probes" \
    --argjson codes "$codes" \
    '{
      name: $name,
      display_name: $display,
      replicas: $replicas,
      autostart_policy: true,
      restart_policy: "always",
      container: $container,
      networking: $networking
    }
    + $probes
    + (if $codes == null then {} else {country_codes: $codes} end)'
}

# PATCH (ContainerGroupPatch) n'accepte ni name ni autostart_policy ni
# restart_policy : on les retire du body complet.
build_patch_body() {
  build_body | jq -c 'del(.name, .autostart_policy, .restart_policy)'
}

# ---------------------------------------------------------------------------
# B' : body du container group de bake (GPU, crane, pas de networking).
# ---------------------------------------------------------------------------
build_bake_body() {
  [ -f "$BAKE_INIT" ] || err "Fichier de bake introuvable : $BAKE_INIT"
  [ -n "$IMAGE" ] || err "SALAD_IMAGE (image engine de base) est requis"
  [ -n "$TARGET_IMAGE" ] || err "SALAD_TARGET_IMAGE est requis (image bakée à produire)"
  [ -n "$REGISTRY_USER" ] || err "SALAD_REGISTRY_USER est requis"
  [ -n "$REGISTRY_PASS" ] || err "SALAD_REGISTRY_PASS est requis"

  local script env resources
  script=$(cat "$BAKE_INIT")
  env=$(jq -cn \
    --arg base "$IMAGE" \
    --arg target "$TARGET_IMAGE" \
    --arg rhost "$REGISTRY_HOST" \
    --arg ruser "$REGISTRY_USER" \
    --arg rpass "$REGISTRY_PASS" \
    --arg family "$STRATA_FAMILY" \
    --arg model "$STRATA_MODEL" \
    --arg context "$STRATA_CONTEXT" \
    --arg vision "$STRATA_VISION" \
    --arg low_ram "$STRATA_LOW_RAM" \
    --arg kv "$STRATA_KV" \
    '{
      BASE_IMAGE: $base,
      TARGET_IMAGE: $target,
      REGISTRY_HOST: $rhost,
      REGISTRY_USER: $ruser,
      REGISTRY_PASS: $rpass,
      STRATA_DATA: "/opt/strata-data",
      FAMILY: $family,
      MODEL: $model,
      CONTEXT: $context,
      VISION: $vision,
      LOW_RAM: $low_ram
    } + (if $kv != "" then {KV: $kv} else {} end)')

  resources=$(jq -cn \
    --argjson cpu "$BAKE_CPU" \
    --argjson mem "$BAKE_MEMORY_MB" \
    --argjson storage "$((BAKE_STORAGE_GB * 1073741824))" \
    --arg gpu_id "$GPU_CLASS_ID" \
    '{cpu: $cpu, memory: $mem, storage_amount: $storage, gpu_classes: [$gpu_id]}')

  jq -cn \
    --arg name "$BAKE_GROUP" \
    --arg image "$IMAGE" \
    --argjson env "$env" \
    --argjson resources "$resources" \
    --arg script "$script" \
    '{
      name: $name,
      display_name: "Strata bake (B-prime)",
      replicas: 1,
      autostart_policy: true,
      restart_policy: "never",
      container: {
        image: $image,
        resources: $resources,
        command: ["/bin/sh", "-c", $script],
        environment_variables: $env,
        image_caching: true,
        priority: "high"
      }
    }'
}

# ===========================================================================
# build / push
# ===========================================================================
cmd_build() {
  need docker
  [ -n "$IMAGE" ] || err "SALAD_IMAGE est requis (ex: docker.io/monuser/strata:3090)"

  local host_arch
  host_arch=$(uname -m)
  if [ "$host_arch" = "arm64" ] || [ "$host_arch" = "aarch64" ]; then
    if [ "${SALAD_ALLOW_QEMU:-0}" != "1" ]; then
      err "Build amd64 depuis un Mac ARM via QEMU : le code CPU de Strata est
     compilé pour le CPU hôte (AVX2/AVX-512), l'image risque d'être
     inutilisable sur les nœuds x86_64 de Salad.
     Recommandé : construire sur une machine x86_64 (VM cloud) avec Docker.
     Pour forcer malgré tout : SALAD_ALLOW_QEMU=1 salad.sh build"
    fi
    info "ATTENTION : build amd64 sous QEMU, code CPU possiblement sous-optimal."
  fi

  if [ -d "$SOURCE_DIR/.git" ]; then
    info "Mise à jour du clone Strata dans $SOURCE_DIR"
    git -C "$SOURCE_DIR" pull --ff-only || info "git pull ignoré (dépôt local modifié ?)"
  else
    info "Clone de $STRATA_REPO dans $SOURCE_DIR"
    git clone --depth 1 "$STRATA_REPO" "$SOURCE_DIR"
  fi

  info "1/2 build de l'image moteur ($BUILD_PLATFORM, CUDA_ARCHITECTURES=$CUDA_ARCH)"
  local base_tag="${IMAGE}-base"
  docker build --platform "$BUILD_PLATFORM" \
    -t "$base_tag" \
    --build-arg "CUDA_ARCHITECTURES=$CUDA_ARCH" \
    --build-arg "BUILD_VISION=$BUILD_VISION" \
    -f "$SOURCE_DIR/Dockerfile" "$SOURCE_DIR"

  if [ "$BAKE" = "1" ]; then
    [ -f "$BAKED_DOCKERFILE" ] || err "Dockerfile.baked introuvable : $BAKED_DOCKERFILE"
    info "2/2 bake du modèle $STRATA_MODEL dans l'image (download ~40-70 Go)"
    docker build --platform "$BUILD_PLATFORM" \
      -t "$IMAGE" \
      --build-arg "BASE_IMAGE=$base_tag" \
      --build-arg "STRATA_FAMILY=$STRATA_FAMILY" \
      --build-arg "STRATA_MODEL=$STRATA_MODEL" \
      --build-arg "STRATA_CONTEXT=$STRATA_CONTEXT" \
      --build-arg "STRATA_VISION=$STRATA_VISION" \
      --build-arg "STRATA_LOW_RAM=$STRATA_LOW_RAM" \
      --build-arg "STRATA_KV=$STRATA_KV" \
      --build-arg "STRATA_KEEP_GGUF=$KEEP_GGUF" \
      -f "$BAKED_DOCKERFILE" "$REPO_DIR"
  else
    info "2/2 mode sans bake : le modèle sera téléchargé au démarrage du container"
    docker tag "$base_tag" "$IMAGE"
  fi

  info "Image construite : $IMAGE"
  info "Pousser avec : salad.sh push"
}

cmd_push() {
  need docker
  [ -n "$IMAGE" ] || err "SALAD_IMAGE est requis"
  info "docker push $IMAGE"
  docker push "$IMAGE"
}

cmd_gpu_classes() {
  require_org_project
  api_call GET "/organizations/$ORG/gpu-classes" || err "Impossible de lister les classes GPU : $(api_detail)"
  jq -r '
    (.items // [])
    | sort_by(.name)
    | .[]
    | "\(.name)  id=\(.id)  type=\(.gpu_class_type)  gpus=\(.gpu_count)  ram=\(.min_ram)-\(.max_ram)Mo  vcpu=\(.min_vcpu)-\(.max_vcpu)"
  ' <<<"$API_LAST_RESPONSE"
}

# ===========================================================================
# deploy / update
# ===========================================================================
group_exists() {
  local name="$1"
  api_call GET "/organizations/$ORG/projects/$PROJECT/containers/$name" 2>/dev/null
}

group_hostname() {
  jq -r '.networking.hostname // empty' <<<"$API_LAST_RESPONSE" 2>/dev/null
}

# Si STRATA_ALLOWED_HOSTS="auto", on ne laisse passer que le hostname de la
# gateway de CE container group (connu via l'API), pas tout *.salad.cloud.
# $1 = nom du group, $2 = 1 si le group vient d'être créé (sinon 0).
resolve_allowed_host() {
  local name="$1" created="${2:-0}" host
  if [ "$created" = "1" ]; then
    host=$(group_hostname)
    if [ -z "$host" ]; then
      api_call GET "/organizations/$ORG/projects/$PROJECT/containers/$name" >/dev/null 2>&1 || true
      host=$(group_hostname)
    fi
  else
    api_call GET "/organizations/$ORG/projects/$PROJECT/containers/$name" >/dev/null 2>&1 || true
    host=$(group_hostname)
  fi
  if [ -n "$host" ]; then
    STRATA_ALLOWED_HOSTS="$host"
    info "allowed_hosts = $host (gateway du container group)"
    return 0
  fi
  STRATA_ALLOWED_HOSTS=""
  info "allowed_hosts : hostname introuvable ; contrôle DNS rebinding laissé au"
  info "  défaut de l'init (.salad.cloud). La clé API Strata le désactive de toute façon."
  return 1
}

cmd_deploy() {
  require_org_project
  [ -n "$IMAGE" ] || err "SALAD_IMAGE est requis (ex: docker.io/monuser/strata:3090)"
  [ -f "$INIT_SCRIPT" ] || err "Fichier d'init introuvable : $INIT_SCRIPT"
  [ -n "${1:-}" ] && GROUP_NAME="$1"

  if [ -z "$STRATA_API_KEY" ]; then
    STRATA_API_KEY=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    info "Clé API Strata générée : ${STRATA_API_KEY:0:8}..."
  fi

  resolve_gpu_class_id

  local path="/organizations/$ORG/projects/$PROJECT/containers"
  local body auto_host=0
  [ "$STRATA_ALLOWED_HOSTS" = "auto" ] && auto_host=1

  if group_exists "$GROUP_NAME"; then
    info "Container group \"$GROUP_NAME\" existe déjà -> PATCH"
    [ "$auto_host" = "1" ] && resolve_allowed_host "$GROUP_NAME" 0
    body=$(build_patch_body)
    if ! api_call PATCH "$path/$GROUP_NAME" "$body"; then
      err "Mise à jour échouée (${API_LAST_STATUS}) : $(api_detail)"
    fi
  else
    info "Création du container group \"$GROUP_NAME\""
    if [ "$auto_host" = "1" ]; then
      # Création sans démarrage : on pose le hostname exact d'abord, puis on
      # démarre (le hostname n'est connu qu'après la création).
      STRATA_ALLOWED_HOSTS=""
      body=$(build_body | jq -c '.autostart_policy=false')
    else
      body=$(build_body)
    fi
    if ! api_call POST "$path" "$body"; then
      err "Création échouée (${API_LAST_STATUS}) : $(api_detail)"
    fi
    if [ "$auto_host" = "1" ]; then
      resolve_allowed_host "$GROUP_NAME" 1 || true
      if [ -n "$STRATA_ALLOWED_HOSTS" ]; then
        body=$(build_patch_body)
        if ! api_call PATCH "$path/$GROUP_NAME" "$body"; then
          err "PATCH allowed_hosts échoué (${API_LAST_STATUS}) : $(api_detail)"
        fi
      fi
    fi
  fi

  save_last_group "$GROUP_NAME"

  info "Démarrage du container group..."
  if ! api_call POST "$path/$GROUP_NAME/start"; then
    case "${API_LAST_STATUS}" in
      409) info "Déjà démarré (409)" ;;
      400) info "Start ignoré (autostart en cours / Pending) : $(api_detail)" ;;
      *)   err "Démarrage échoué (${API_LAST_STATUS}) : $(api_detail)" ;;
    esac
  fi

  cmd_status "$GROUP_NAME"
}

cmd_update() {
  require_org_project
  resolve_gpu_class_id
  local name
  name=$(get_group_name "${1:-}")
  GROUP_NAME="$name"
  local path="/organizations/$ORG/projects/$PROJECT/containers/$name"

  # PATCH remplace TOUT environment_variables : on relit l'existant pour ne pas
  # effacer la clé API (si STRATA_API_KEY n'est pas fourni) et pour récupérer le
  # hostname de la gateway (allowed_hosts=auto).
  local existing=""
  if api_call GET "$path"; then
    existing="$API_LAST_RESPONSE"
    if [ -z "$STRATA_API_KEY" ]; then
      STRATA_API_KEY=$(jq -r '
        (.container.environment_variables.STRATA_API_KEY //
         .container.environment_variables.API_KEY // empty)' <<<"$existing")
      [ -n "$STRATA_API_KEY" ] && info "Clé API Strata conservée depuis le group existant"
    fi
    if [ "$STRATA_ALLOWED_HOSTS" = "auto" ]; then
      local host
      host=$(group_hostname)
      [ -n "$host" ] && { STRATA_ALLOWED_HOSTS="$host"; info "allowed_hosts = $host (gateway)"; }
    fi
  fi

  info "PATCH $name"
  local body
  body=$(build_patch_body)
  if ! api_call PATCH "$path" "$body"; then
    err "Mise à jour échouée (${API_LAST_STATUS}) : $(api_detail)"
  fi
  cmd_status "$name"
}

# ===========================================================================
# bake (B') : préparer sur un container GPU Salad + pousser via crane
# ===========================================================================
cmd_bake() {
  require_org_project
  [ -n "$IMAGE" ] || err "SALAD_IMAGE (image engine de base, non bakée) est requis"
  [ -f "$BAKE_INIT" ] || err "Fichier de bake introuvable : $BAKE_INIT"

  if [ -z "$TARGET_IMAGE" ]; then
    TARGET_IMAGE="${IMAGE%%:*}:${STRATA_MODEL}-baked"
  fi

  resolve_gpu_class_id

  info "Bake B' : $IMAGE -> $TARGET_IMAGE (registry $REGISTRY_HOST)"
  info "group=$BAKE_GROUP  cpu=$BAKE_CPU ram=${BAKE_MEMORY_MB}Mo storage=${BAKE_STORAGE_GB}Go  modèle=$STRATA_MODEL"

  local path="/organizations/$ORG/projects/$PROJECT/containers"
  local body
  if group_exists "$BAKE_GROUP"; then
    info "Container group \"$BAKE_GROUP\" existe -> PATCH"
    body=$(build_bake_body | jq -c 'del(.name, .autostart_policy, .restart_policy)')
    api_call PATCH "$path/$BAKE_GROUP" "$body" || err "Mise à jour échouée (${API_LAST_STATUS}) : $(api_detail)"
  else
    info "Création du container group de bake \"$BAKE_GROUP\""
    body=$(build_bake_body)
    api_call POST "$path" "$body" || err "Création échouée (${API_LAST_STATUS}) : $(api_detail)"
  fi
  save_last_group "$BAKE_GROUP"

  info "Démarrage du bake..."
  if ! api_call POST "$path/$BAKE_GROUP/start"; then
    case "${API_LAST_STATUS}" in
      400|409) info "Start ignoré (${API_LAST_STATUS}) : $(api_detail)" ;;
      *) err "Démarrage échoué (${API_LAST_STATUS}) : $(api_detail)" ;;
    esac
  fi

  echo ""
  info "Suivi :  ./salad.sh logs $BAKE_GROUP"
  info "Nettoyage après succès :  ./salad.sh delete $BAKE_GROUP"
  info "Déploiement de l'image bakée :  SALAD_IMAGE=$TARGET_IMAGE SALAD_DATA_DIR=/opt/strata-data ./salad.sh deploy"
  cmd_status "$BAKE_GROUP"
}

# ===========================================================================
# start / stop / status / logs / delete
# ===========================================================================
cmd_start() {
  require_org_project
  local name
  name=$(get_group_name "${1:-}")
  local path="/organizations/$ORG/projects/$PROJECT/containers/$name"
  info "Démarrage de $name..."
  if ! api_call POST "$path/start"; then
    [ "${API_LAST_STATUS}" = "409" ] && { info "Déjà démarré"; return 0; }
    err "Démarrage échoué (${API_LAST_STATUS}) : $(api_detail)"
  fi
  info "Container group $name démarré"
}

cmd_stop() {
  require_org_project
  local name
  name=$(get_group_name "${1:-}")
  local path="/organizations/$ORG/projects/$PROJECT/containers/$name"
  info "Arrêt de $name..."
  if ! api_call POST "$path/stop"; then
    [ "${API_LAST_STATUS}" = "409" ] && { info "Déjà arrêté"; return 0; }
    err "Arrêt échoué (${API_LAST_STATUS}) : $(api_detail)"
  fi
  info "Container group $name arrêté"
}

cmd_status() {
  require_org_project
  local name
  name=$(get_group_name "${1:-}")
  local path="/organizations/$ORG/projects/$PROJECT/containers/$name"

  if ! api_call GET "$path"; then
    err "Impossible de lire $name (${API_LAST_STATUS}) : $(api_detail)"
  fi

  jq -r '
    "Nom:        \(.name)",
    "État:       \(.current_state.status // "n/a")  (replicas: \(.current_state.replicas // 0)/\(.replicas // 0))",
    "Image:      \(.container.image)",
    "GPU:        \((.container.resources.gpu_classes // []) | join(", "))",
    "CPU/RAM:    \(.container.resources.cpu) vCPU / \(.container.resources.memory) Mo",
    "Priorité:   \(.container.priority // "n/a")",
    "Port:       \(.networking.port // "n/a")  auth=\(.networking.auth // "n/a")",
    "URL:        \(.networking.hostname // "n/a")"
  ' <<<"$API_LAST_RESPONSE"

  echo "Instances:"
  api_call GET "$path/instances" >/dev/null 2>&1 && \
    jq -r '
      (.instances // [])[]
      | "  \(.machine_id // "?")  \(.state // "?")  \(.version // "")"
    ' <<<"$API_LAST_RESPONSE" || echo "  (liste indisponible)"
}

cmd_logs() {
  require_org_project
  local name
  name=$(get_group_name "${1:-}")
  local path="/organizations/$ORG/projects/$PROJECT/containers/$name/system-logs"
  api_call GET "$path" || err "Logs indisponibles (${API_LAST_STATUS}) : $(api_detail)"
  jq -r '
    (.items // .entries // .logs // [])
    | if type=="array" then .[] | "[\(.timestamp // "?")] \(.message // tostring)" else tostring end
  ' <<<"$API_LAST_RESPONSE" 2>/dev/null || echo "$API_LAST_RESPONSE"
}

cmd_delete() {
  require_org_project
  local name
  name=$(get_group_name "${1:-}")
  local path="/organizations/$ORG/projects/$PROJECT/containers/$name"
  info "Suppression de $name (irréversible)..."
  if ! api_call DELETE "$path"; then
    err "Suppression échouée (${API_LAST_STATUS}) : $(api_detail)"
  fi
  info "Container group $name supprimé"
  if [ -f "$LAST_GROUP_FILE" ] && [ "$(cat "$LAST_GROUP_FILE")" = "$name" ]; then
    rm -f "$LAST_GROUP_FILE"
  fi
}

# ===========================================================================
# usage / dispatch
# ===========================================================================
usage() {
  cat <<EOF
Usage: salad.sh <commande> [options]

Commandes:
  build                 Construire l'image Strata (x86_64, arch RTX 3090=86)
  push                  Pousser l'image vers le registry
  gpu-classes           Lister les classes GPU (trouver l'UUID RTX 3090)
  deploy [NAME]         Créer (ou MAJ) + démarrer le container group
  update [NAME]         Mettre à jour le container group existant (PATCH)
  bake                  B' : préparer sur un container GPU Salad + push crane
  start  [NAME]         Démarrer
  stop   [NAME]         Arrêter
  status [NAME]         État, URL, instances
  logs   [NAME]         Logs système
  delete [NAME]         Supprimer (irréversible)

Env requises : SALAD_API_KEY, SALAD_ORG, SALAD_PROJECT, SALAD_IMAGE
Modèle       : STRATA_MODEL=${STRATA_MODEL}  STRATA_CONTEXT=${STRATA_CONTEXT}  STRATA_FAMILY=${STRATA_FAMILY}
GPU          : SALAD_GPU_CLASS="${SALAD_GPU_CLASS}"  SALAD_CPU=${CPU}  SALAD_MEMORY_MB=${MEMORY_MB}

Modes:
  SALAD_BAKE=1          modèle baké dans l'image (build)
  SALAD_RUNTIME_BUILD=1 installer/builder Strata au démarrage (image générique, sans registry)
EOF
}

case "${1:-}" in
  -h|--help|"") usage; [ -n "${1:-}" ] || exit 1; exit 0 ;;
esac

[ -n "${SALAD_API_KEY:-}" ] || err "SALAD_API_KEY est requis"

case "$1" in
  build)       shift; cmd_build "$@" ;;
  push)        shift; cmd_push "$@" ;;
  gpu-classes) shift; cmd_gpu_classes "$@" ;;
  deploy)      shift; cmd_deploy "$@" ;;
  update)      shift; cmd_update "$@" ;;
  bake)        shift; cmd_bake "$@" ;;
  start)       shift; cmd_start "$@" ;;
  stop)        shift; cmd_stop "$@" ;;
  status)      shift; cmd_status "$@" ;;
  logs)        shift; cmd_logs "$@" ;;
  delete)      shift; cmd_delete "$@" ;;
  *) usage; exit 1 ;;
esac
   