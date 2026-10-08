#!/bin/sh
# salad-container-init.sh
# ---------------------------------------------------------------------------
# Commande de container pour faire tourner Strata sur SaladCloud.
#
# SaladCloud écrase l'ENTRYPOINT de l'image quand on fournit un champ
# "command" dans le container group. Ce script sert donc de commande :
#   1. il pose les valeurs par défaut (lues ensuite par Strata),
#   2. il tente de lever la limite memlock (Strata verrouille des dizaines de
#      Go de RAM pour le GPU),
#   3. il passe la main à l'entrypoint de Strata (image Niko1221/Strata),
#      qui télécharge le modèle (reprise possible) puis lance le serveur
#      OpenAI/Anthropic sur le port $PORT.
#
# Les vraies valeurs (modèle, contexte, clé API, …) sont fournies par
# salad.sh via les variables d'environnement du container group.
#
# Fichier analogue à container-init.sh (Runpod) mais pour Strata + Salad.
# ---------------------------------------------------------------------------

set -e
cd /opt/strata || exit 1

# --- Valeurs par défaut (surchargées par l'env du container group) ----------
export STRATA_DATA="${STRATA_DATA:-/data}"
export FAMILY="${FAMILY:-qwen}"          # qwen | swift | coder | unsloth
export MODEL="${MODEL:-IQ2_XS}"          # IQ2_XS | Q2_0 | IQ3_XXS | IQ3_S
export CONTEXT="${CONTEXT:-32768}"
export VISION="${VISION:-no}"            # no | yes | cpu
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-8080}"
export LOW_RAM="${LOW_RAM:-on}"          # on: experts mappés depuis le pack
export STRATA_EXECV="${STRATA_EXECV:-1}" # le serveur devient PID 1 (SIGTERM)

# ---------------------------------------------------------------------------
# memlock : l'entrypoint Runpod/Strata utilise `--ulimit memlock=-1`. Salad
# n'expose pas les ulimits, on tente de lever la limite ici. Si ça échoue
# (pas de CAP_SYS_RESOURCE), le moteur tourne quand même, avec plus de
# défauts de page pendant le chargement.
# ---------------------------------------------------------------------------
ulimit -l unlimited 2>/dev/null || true

mkdir -p "$STRATA_DATA"

echo "[salad-init] ------------------------------------------------------------"
echo "[salad-init] Strata  famille=$FAMILY  modèle=$MODEL  ctx=$CONTEXT"
echo "[salad-init] vision=$VISION  low_ram=$LOW_RAM  host=$HOST  port=$PORT"
echo "[salad-init] data   $STRATA_DATA  ($(df -h "$STRATA_DATA" 2>/dev/null | tail -1))"
echo "[salad-init] note: ~70 Go à télécharger au 1er démarrage (cache disque"
echo "[salad-init]       EPHEMERE sur Salad : refait à chaque nouvelle instance)"
echo "[salad-init] ------------------------------------------------------------"

# --- Handover à l'entrypoint officiel de l'image Strata ---------------------
# Il lit FAMILY/MODEL/CONTEXT/VISION/HOST/PORT/API_KEY/LOW_RAM/KV et, au
# premier lancement, exécute `setup.py --setup --yes` puis démarre le serveur.
if [ -f /opt/strata/docker-entrypoint.sh ]; then
  exec /opt/strata/docker-entrypoint.sh
else
  echo "[salad-init] FATAL: /opt/strata/docker-entrypoint.sh absent (mauvaise image ?)" >&2
  exit 1
fi
