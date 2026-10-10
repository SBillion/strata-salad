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

# --- DNS rebinding : autorise le nom de la gateway Salad --------------------
# La gateway relaie les requêtes avec Host=<group>.<...>.salad.cloud. Sans clé
# API (cf. plus bas), le serveur Strata refuse tout nom inconnu (403 « Host ...
# is not allowed (DNS rebinding protection) »). On autorise tout *.salad.cloud.
export STRATA_ALLOWED_HOSTS="${STRATA_ALLOWED_HOSTS:-.salad.cloud}"

# --- Clé API du serveur Strata ----------------------------------------------
# Attention : le serveur lit STRATA_API_KEY, l'entrypoint/ setup.py lit API_KEY.
# Une image bakée a un strata-<model>.json avec "api_key": "" (setup fait au
# build sans clé) et l'entrypoint ne relance PAS setup au démarrage : sans
# injection, la clé fournie par salad.sh est ignorée. On propage donc API_KEY
# vers STRATA_API_KEY (sans jamais l'exporter vide : le serveur sortirait).
if [ -z "${STRATA_API_KEY:-}" ] && [ -n "${API_KEY:-}" ]; then
  export STRATA_API_KEY="$API_KEY"
fi

# ---------------------------------------------------------------------------
# memlock : l'entrypoint Runpod/Strata utilise `--ulimit memlock=-1`. Salad
# n'expose pas les ulimits, on tente de lever la limite ici. Si ça échoue
# (pas de CAP_SYS_RESOURCE), le moteur tourne quand même, avec plus de
# défauts de page pendant le chargement.
# ---------------------------------------------------------------------------
ulimit -l unlimited 2>/dev/null || true

mkdir -p "$STRATA_DATA"

# ---------------------------------------------------------------------------
# IPv6 -> IPv4 : la gateway/probe SaladCloud communique en IPv6, mais Strata
# bind $HOST=0.0.0.0 (IPv4 seul). Sans relais, la readiness probe ne passe
# jamais (ready=False, 503 côté gateway) même si le serveur tourne.
# socat écoute en IPv6 sur $PORT et forwarde vers 127.0.0.1:$PORT.
# ---------------------------------------------------------------------------
if ! command -v socat >/dev/null 2>&1; then
  echo "[salad-init] installation de socat (relais IPv6 -> IPv4)"
  apt-get update >/dev/null 2>&1 && apt-get install -y --no-install-recommends socat >/dev/null 2>&1
  rm -rf /var/lib/apt/lists/* 2>/dev/null || true
fi
if command -v socat >/dev/null 2>&1; then
  socat "TCP6-LISTEN:${PORT},ipv6only=1,fork,reuseaddr" "TCP4:127.0.0.1:${PORT}" &
  echo "[salad-init] socat [::]:${PORT} -> 127.0.0.1:${PORT} (pid $!)"
else
  echo "[salad-init] ATTENTION: socat indisponible -> la gateway Salad (IPv6) ne joindra pas l'app"
fi

echo "[salad-init] ------------------------------------------------------------"
echo "[salad-init] Strata  famille=$FAMILY  modèle=$MODEL  ctx=$CONTEXT"
echo "[salad-init] vision=$VISION  low_ram=$LOW_RAM  host=$HOST  port=$PORT"
echo "[salad-init] data   $STRATA_DATA  ($(df -h "$STRATA_DATA" 2>/dev/null | tail -1))"
echo "[salad-init] note: ~70 Go à télécharger au 1er démarrage (cache disque"
echo "[salad-init]       EPHEMERE sur Salad : refait à chaque nouvelle instance)"
echo "[salad-init] ------------------------------------------------------------"

# --- Chemin normal : on laisse l'entrypoint officiel faire setup + serve ----
if [ -z "${CONVERSATION_CACHE_MIB:-}" ]; then
  if [ -f /opt/strata/docker-entrypoint.sh ]; then
    exec /opt/strata/docker-entrypoint.sh
  fi
  echo "[salad-init] FATAL: /opt/strata/docker-entrypoint.sh absent (mauvaise image ?)" >&2
  exit 1
fi

# --- Cache de conversation (optionnel) --------------------------------------
# setup.py n'expose pas --conversation-cache-mib : il faut l'écrire dans la
# config générée. On refait donc setup nous-mêmes (--no-start), on patche la
# config, puis on démarre. Utile pour les prompts longs multi-tours.
prefix=""
[ "$FAMILY" != "qwen" ] && prefix="$FAMILY-"
tag="${prefix}$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')"
cfg="$STRATA_DATA/config/strata-$tag.json"

mkdir -p "$STRATA_DATA/config"
if [ "${REINSTALL:-0}" = "1" ] || [ ! -f "$cfg" ]; then
  echo "[salad-init] setup.py --setup (download + pack si nécessaire)"
  .venv/bin/python setup.py --setup --yes \
    --family "$FAMILY" --model "$MODEL" --context "$CONTEXT" --vision "$VISION" \
    --low-ram "$LOW_RAM" \
    ${KV:+--kv "$KV"} \
    --data-dir "$STRATA_DATA" --host "$HOST" --port "$PORT" \
    --api-key "${API_KEY:-}" --no-start
fi

generated="/opt/strata/strata-$tag.json"
if [ -f "$generated" ] && [ ! -f "$cfg" ]; then
  cp -f "$generated" "$cfg"
fi
if [ ! -f "$cfg" ]; then
  echo "[salad-init] FATAL: setup did not create $cfg or $generated" >&2
  exit 1
fi

if [ -n "$CONVERSATION_CACHE_MIB" ]; then
  .venv/bin/python - "$cfg" "$CONVERSATION_CACHE_MIB" <<'PY'
import json, sys
p, n = sys.argv[1], str(sys.argv[2])
d = json.load(open(p))
a = d.setdefault("args", [])
if "--conversation-cache-mib" not in a:
    a += ["--conversation-cache-mib", n]
    json.dump(d, open(p, "w"))
    print("[salad-init] conversation-cache-mib =", n)
PY
fi
ln -sfn "$cfg" "$generated" 2>/dev/null || true

echo "[salad-init] démarrage du serveur (avec cache de conversation)"
exec .venv/bin/python setup.py --port "$PORT"
