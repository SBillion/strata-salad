#!/bin/sh
# salad-bake-init.sh
# ---------------------------------------------------------------------------
# B' : bake Strata's prepared data into an image, from a SaladCloud GPU
# container, WITHOUT a Docker daemon.
#
#   1. setup.py --setup --yes (GPU visible ici -> son check matériel passe)
#      telecharge le modele et prepare pack + MTP dans $STRATA_DATA
#   2. crane (binaire statique) empile $STRATA_DATA comme une couche sur
#      l'image engine de base et push vers le registry (GHCR...)
#
# Le tar est STREAME (FIFO) vers crane : pas de copie de 100 Go en plus sur
# le disque ephemere du container.
#
# Env requis : BASE_IMAGE, TARGET_IMAGE, REGISTRY_USER, REGISTRY_PASS
# Env optionnel : REGISTRY_HOST (ghcr.io), FAMILY, MODEL, CONTEXT, VISION,
#                 LOW_RAM, KV, STRATA_DATA, CRANE_VERSION
# ---------------------------------------------------------------------------

set -e
cd /opt/strata || exit 1

export DEBIAN_FRONTEND=noninteractive
export STRATA_DATA="${STRATA_DATA:-/opt/strata-data}"

: "${BASE_IMAGE:?BASE_IMAGE requis}"
: "${TARGET_IMAGE:?TARGET_IMAGE requis}"
: "${REGISTRY_USER:?REGISTRY_USER requis}"
: "${REGISTRY_PASS:?REGISTRY_PASS requis}"
REGISTRY_HOST="${REGISTRY_HOST:-ghcr.io}"
FAMILY="${FAMILY:-qwen}"
MODEL="${MODEL:-IQ2_XS}"
CONTEXT="${CONTEXT:-32768}"
VISION="${VISION:-no}"
LOW_RAM="${LOW_RAM:-on}"
KV="${KV:-}"
CRANE_VERSION="${CRANE_VERSION:-v0.20.2}"

log() { echo "[salad-bake] $*"; }

# --- crane (statique, pas de daemon) ---------------------------------------
if ! command -v crane >/dev/null 2>&1; then
  log "installation de crane ${CRANE_VERSION}"
  curl -fsSL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \
    -o /tmp/crane.tgz
  tar -xzf /tmp/crane.tgz -C /usr/local/bin crane
  chmod +x /usr/local/bin/crane
fi
log "crane: $(crane version 2>/dev/null | head -1)"

# --- 1. préparer le modèle (le GPU est visible -> setup.py passe) -----------
log "setup.py --setup : modèle=$MODEL ctx=$CONTEXT low_ram=$LOW_RAM"
mkdir -p "$STRATA_DATA"
.venv/bin/python setup.py --setup --yes \
  --family "$FAMILY" \
  --model "$MODEL" \
  --context "$CONTEXT" \
  --vision "$VISION" \
  --low-ram "$LOW_RAM" \
  ${KV:+--kv "$KV"} \
  --data-dir "$STRATA_DATA" \
  --no-start

log "taille préparée : $(du -sh "$STRATA_DATA" | cut -f1)"

# --- 2. auth registry -------------------------------------------------------
log "crane auth login $REGISTRY_HOST (user=$REGISTRY_USER)"
crane auth login "$REGISTRY_HOST" -u "$REGISTRY_USER" -p "$REGISTRY_PASS"

# --- 3. tar streamé (FIFO) -> crane append ---------------------------------
REL="${STRATA_DATA#/}"                 # opt/strata-data (chemins relatifs à /)
FIFO="/tmp/strata-layer.tar"
rm -f "$FIFO"
mkfifo "$FIFO"

log "append de /$REL sur $BASE_IMAGE -> $TARGET_IMAGE"
crane append --base "$BASE_IMAGE" --new_layer "$FIFO" --tag "$TARGET_IMAGE" &
CPID=$!

tar -C / -cf "$FIFO" "$REL"
wait "$CPID"

log "OK : $TARGET_IMAGE"
log "déploiement : SALAD_IMAGE=$TARGET_IMAGE SALAD_DATA_DIR=$STRATA_DATA ./salad.sh deploy"
