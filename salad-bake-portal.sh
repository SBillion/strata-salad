#!/bin/sh
# salad-bake-portal.sh
# ---------------------------------------------------------------------------
# À exécuter DANS le terminal du Portail Salad d'une instance Strata DÉJÀ PRÊTE
# (ex: strata-qwen, dont /data contient le modèle + pack + MTP).
#
# Réutilise les données préparées -> AUCUN re-download. Empile /data comme
# couche sur l'image engine de base via crane (pas de daemon Docker) et push.
#
# Usage dans le terminal Portail :
#   export REGISTRY_USER=SBillion
#   export REGISTRY_PASS=<PAT avec write:packages>
#   curl -fsSL https://raw.githubusercontent.com/SBillion/strata-salad/main/salad-bake-portal.sh | sh
#
# Env optionnel :
#   BASE_IMAGE   (défaut ghcr.io/sbillion/strata-salad:IQ2_XS)
#   TARGET_IMAGE (défaut ghcr.io/sbillion/strata-salad:IQ2_XS-baked)
#   DATA_DIR     (défaut /data)   <- doit correspondre à STRATA_DATA du runtime
#   CRANE_VERSION(défaut v0.20.2)
# ---------------------------------------------------------------------------

set -e

BASE_IMAGE="${BASE_IMAGE:-ghcr.io/sbillion/strata-salad:IQ2_XS}"
TARGET_IMAGE="${TARGET_IMAGE:-ghcr.io/sbillion/strata-salad:IQ2_XS-baked}"
REGISTRY_HOST="${REGISTRY_HOST:-ghcr.io}"
DATA_DIR="${DATA_DIR:-/data}"
CRANE_VERSION="${CRANE_VERSION:-v0.20.2}"

: "${REGISTRY_USER:?export REGISTRY_USER=<user>}"
: "${REGISTRY_PASS:?export REGISTRY_PASS=<PAT write:packages>}"

[ -d "$DATA_DIR" ] || { echo "FATAL: $DATA_DIR introuvable (mauvaise instance ?)"; exit 1; }
echo "[bake] données: $(du -sh "$DATA_DIR" 2>/dev/null | cut -f1) dans $DATA_DIR"

# --- crane (binaire statique) ----------------------------------------------
if ! command -v crane >/dev/null 2>&1; then
  echo "[bake] installation de crane ${CRANE_VERSION}"
  curl -fsSL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" -o /tmp/crane.tgz
  tar -xzf /tmp/crane.tgz -C /usr/local/bin crane
  chmod +x /usr/local/bin/crane
fi
crane version 2>/dev/null | head -1 || true

# --- auth -------------------------------------------------------------------
echo "[bake] crane auth login $REGISTRY_HOST ($REGISTRY_USER)"
crane auth login "$REGISTRY_HOST" -u "$REGISTRY_USER" -p "$REGISTRY_PASS"

# --- tar streamé (FIFO) -> crane append ------------------------------------
REL="${DATA_DIR#/}"
FIFO="/tmp/strata-layer.tar"
rm -f "$FIFO"
mkfifo "$FIFO"

echo "[bake] append /$REL sur $BASE_IMAGE -> $TARGET_IMAGE (push GHCR)"
crane append --base "$BASE_IMAGE" --new_layer "$FIFO" --tag "$TARGET_IMAGE" &
CPID=$!
tar -C / -cf "$FIFO" "$REL"
wait "$CPID"

echo "[bake] OK : $TARGET_IMAGE"
echo "[bake] déployer : SALAD_IMAGE=$TARGET_IMAGE SALAD_DATA_DIR=$DATA_DIR ./salad.sh deploy"
