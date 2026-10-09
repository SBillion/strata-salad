#!/bin/sh
# salad-runtime-init.sh
# ---------------------------------------------------------------------------
# Installe ET lance Strata À L'INTÉRIEUR du container Salad, au démarrage.
#
# À utiliser avec une image PUBLIQUE générique (défaut nvidia/cuda:13.0.0-devel-
# ubuntu24.04) : aucun build ni push de registry pour ce dépôt.
#
#   Salade démarre l'image cuda:devel
#     -> ce script : apt deps -> git clone Strata -> venv + pip
#        -> setup.py (engine pré-compilé RTX 30/40/50, ou compilation)
#        -> téléchargement du modèle (~40-70 Go)
#        -> serveur OpenAI/Anthropic sur $PORT
#
# ATTENTION : le disque Salad est ÉPHÉMÈRE. Toute l'installation et le
# téléchargement du modèle sont refaits à CHAQUE nouvelle instance (et une
# instance peut être réallouée). Bien pour tester ; pour la prod, préférer
# l'image bakée (Dockerfile.baked) ou l'image pré-construite par la CI.
# ---------------------------------------------------------------------------

set -e

export DEBIAN_FRONTEND=noninteractive
export STRATA_DATA="${STRATA_DATA:-/data}"
export FAMILY="${FAMILY:-qwen}"
export MODEL="${MODEL:-IQ2_XS}"
export CONTEXT="${CONTEXT:-32768}"
export VISION="${VISION:-no}"
export LOW_RAM="${LOW_RAM:-on}"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-8080}"
export STRATA_EXECV="${STRATA_EXECV:-1}"

# --- DNS rebinding : autorise le nom de la gateway Salad --------------------
# La gateway relaie avec Host=<group>.<...>.salad.cloud ; sans clé API le
# serveur Strata refuse ce nom (403 « DNS rebinding protection »). On autorise
# tout *.salad.cloud.
export STRATA_ALLOWED_HOSTS="${STRATA_ALLOWED_HOSTS:-.salad.cloud}"

# --- Clé API du serveur Strata ----------------------------------------------
# Le serveur lit STRATA_API_KEY ; API_KEY ne sert qu'à setup.py. On propage
# (jamais vide : le serveur sortirait si STRATA_API_KEY était défini vide).
if [ -z "${STRATA_API_KEY:-}" ] && [ -n "${API_KEY:-}" ]; then
  export STRATA_API_KEY="$API_KEY"
fi

STRATA_HOME="${STRATA_HOME:-/opt/strata}"
STRATA_REPO="${STRATA_REPO:-https://github.com/Niko1221/Strata.git}"

log() { echo "[salad-runtime] $*"; }

# --- 1. Dépendances système ------------------------------------------------
# L'image cuda:devel fournit déjà nvcc + les libs CUDA ; il manque git/python.
if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  log "apt-get install (git, python3, build-essential, ...)"
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git libatomic1 libgomp1 \
    python3 python3-pip python3-venv unzip
  rm -rf /var/lib/apt/lists/*
fi

# --- 2. Clone Strata --------------------------------------------------------
if [ ! -d "$STRATA_HOME/.git" ]; then
  log "git clone $STRATA_REPO -> $STRATA_HOME"
  mkdir -p "$(dirname "$STRATA_HOME")"
  git clone --depth 1 "$STRATA_REPO" "$STRATA_HOME"
fi
cd "$STRATA_HOME" || exit 1

# --- 3. venv + dépendances Python ------------------------------------------
if [ ! -x .venv/bin/python ]; then
  log "création du venv + pip install -r requirements.txt"
  python3 -m venv .venv
  .venv/bin/pip install --no-cache-dir --upgrade pip
  .venv/bin/pip install --no-cache-dir -r requirements.txt
fi
chmod +x setup.sh 2>/dev/null || true

# --- 4. memlock -------------------------------------------------------------
ulimit -l unlimited 2>/dev/null || true
mkdir -p "$STRATA_DATA"

# --- 4b. IPv6 -> IPv4 (gateway/probe SaladCloud parle IPv6) -----------------
# Strata bind 0.0.0.0 (IPv4 seul) : socat écoute en IPv6 sur $PORT et
# forwarde vers 127.0.0.1:$PORT, sinon la readiness ne passe jamais.
if ! command -v socat >/dev/null 2>&1; then
  log "apt-get install socat (relais IPv6 -> IPv4)"
  apt-get update >/dev/null 2>&1 && apt-get install -y --no-install-recommends socat >/dev/null 2>&1
  rm -rf /var/lib/apt/lists/* 2>/dev/null || true
fi
if command -v socat >/dev/null 2>&1; then
  socat "TCP6-LISTEN:${PORT},ipv6only=1,fork,reuseaddr" "TCP4:127.0.0.1:${PORT}" &
  log "socat [::]:${PORT} -> 127.0.0.1:${PORT}"
fi

log "Strata  famille=$FAMILY  modèle=$MODEL  ctx=$CONTEXT  vision=$VISION  low_ram=$LOW_RAM"
log "data=$STRATA_DATA  ($(df -h "$STRATA_DATA" 2>/dev/null | tail -1))"
log "setup.py va installer l'engine (pré-compilé) et télécharger le modèle (~40-70 Go)"

# --- 5. Setup non interactif (engine + modèle) ------------------------------
.venv/bin/python setup.py --setup --yes \
  --family "$FAMILY" \
  --model "$MODEL" \
  --context "$CONTEXT" \
  --vision "$VISION" \
  --low-ram "$LOW_RAM" \
  --data-dir "$STRATA_DATA" \
  --host "$HOST" \
  --port "$PORT" \
  --api-key "${API_KEY:-}" \
  --no-start

# --- 6. Serveur -------------------------------------------------------------
log "démarrage du serveur sur $HOST:$PORT"
exec .venv/bin/python setup.py --port "$PORT"
