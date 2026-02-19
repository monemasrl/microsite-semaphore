#!/usr/bin/env bash

# I parametri sono passati come var1=val1 var2=val2 ... al comando di esecuzione dello script (es: via API o survey vars).

for arg in "$@"; do
  KEY="${arg%%=*}"
  VALUE="${arg#*=}"
  declare -A args
  args["$KEY"]="$VALUE"
done

# Export the arguments as environment variables
for key in "${!args[@]}"; do
  export "$key"="${args[$key]}"
done

# ---- Required params (passali via API / survey vars) ----
: "${SITE_ID:?missing SITE_ID}"
: "${GIT_REF:?missing GIT_REF}"                         # es: main, tag, commit
: "${CF_PAGES_PROJECT:?missing CF_PAGES_PROJECT}"       # nome progetto Pages
: "${CLOUDFLARE_API_TOKEN:?missing CLOUDFLARE_API_TOKEN}"

: "${CONFIG_URL:?missing CONFIG_URL}"                   # URL del file config da scaricare

# ---- Optional params ----
HUGO_BASEURL="${HUGO_BASEURL:-}"                        # es https://example.com
CF_BRANCH="${CF_BRANCH:-}"                              # es preview-foo (se vuoi preview)
CONFIG_FILENAME="${CONFIG_FILENAME:-config.runtime.yaml}" # come salvare il file scaricato
CONFIG_SUBDIR_IN_DATA="${CONFIG_SUBDIR_IN_DATA:-}"      # es "dynamic" -> data/dynamic/<file>

# ---- Images ----
HUGO_IMAGE="${HUGO_IMAGE:-klakegg/hugo:0.126.2-ext-alpine}"     # o la tua immagine builder
WRANGLER_IMAGE="${WRANGLER_IMAGE:-node:20-alpine}"              # useremo npx wrangler dentro
# Se hai un'immagine wrangler dedicata, mettila qui (consigliato)
# WRANGLER_IMAGE="cloudflare/wrangler:latest"  (se la tua org la usa)

# ---- Paths ----
JOB_ID="${SEMAPHORE_JOB_ID:-$$}"
BASE_RUN_DIR="/tmp/semaphore/runs"
RUN_DIR="${BASE_RUN_DIR}/${JOB_ID}"
SRC_DIR="${SRC_DIR:-$PWD}"        # Semaphore di solito esegue nel working copy del repo
OUT_DIR="${RUN_DIR}/out"
CFG_DIR="${RUN_DIR}/cfg"


echo "==> [${SITE_ID}] run=${JOB_ID}"
echo "==> SRC_DIR=$SRC_DIR"
echo "==> OUT_DIR=$OUT_DIR"
echo "==> CONFIG_URL=$CONFIG_URL"

mkdir -p "$OUT_DIR" "$CFG_DIR"

# ---- 1) Download config file ----
CFG_PATH="${CFG_DIR}/${CONFIG_FILENAME}"

# download con timeout e fail su HTTP != 2xx
curl -fsSL --connect-timeout 10 --max-time 60 \
  -o "$CFG_PATH" \
  "$CONFIG_URL"

# controllo banale: non vuoto
if [[ ! -s "$CFG_PATH" ]]; then
  echo "ERROR: downloaded config is empty: $CFG_PATH" >&2
  exit 1
fi

# (opzionale) se vuoi imporre un checksum passato come param:
# : "${CONFIG_SHA256:?missing CONFIG_SHA256}"
# echo "${CONFIG_SHA256}  ${CFG_PATH}" | sha256sum -c -

echo "==> Downloaded config to $CFG_PATH"

# ---- 2) Build Hugo in container ----
# Montiamo:
# - repo: read-only in /work
# - output: rw in /out
# - config: in /work/data/... (Hugo data dir)
#
# N.B. data/ deve esistere nel repo, altrimenti Hugo non lo vede (lo creiamo via mount target).
DATA_TARGET="/work/data"
if [[ -n "$CONFIG_SUBDIR_IN_DATA" ]]; then
  DATA_TARGET="/work/data/${CONFIG_SUBDIR_IN_DATA}"
fi

echo "==> Building with Hugo image: $HUGO_IMAGE"
docker run --rm \
  --name "hugo-build-${SITE_ID}-${JOB_ID}" \
  -v "$SRC_DIR:/work:ro" \
  -v "$OUT_DIR:/out:rw" \
  -v "$CFG_PATH:${DATA_TARGET}/${CONFIG_FILENAME}:ro" \
  -w /work \
  "$HUGO_IMAGE" \
  sh -lc '
    set -euo pipefail
    echo "Hugo version:"
    hugo version

    mkdir -p /out/public

    # Hugo build
    if [ -n "${HUGO_BASEURL:-}" ]; then
      hugo --minify --destination /out/public --baseURL "$HUGO_BASEURL"
    else
      hugo --minify --destination /out/public
    fi
  '

if [[ ! -d "${OUT_DIR}/public" ]]; then
  echo "ERROR: build output missing: ${OUT_DIR}/public" >&2
  exit 1
fi

echo "==> Build OK: ${OUT_DIR}/public"

# ---- 3) Deploy via Wrangler container ----
echo "==> Deploying with Wrangler image: $WRANGLER_IMAGE"

# Se usi node:alpine, installiamo wrangler al volo con npx -y (semplice, ma più lento).
# Se hai una immagine wrangler dedicata, è più veloce e prevedibile.

if [[ -z "$CF_BRANCH" ]]; then
  docker run --rm \
    -e CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN" \
    -v "$OUT_DIR/public:/site:ro" \
    "$WRANGLER_IMAGE" \
    pages deploy /site --project-name "$CF_PAGES_PROJECT"
  echo "==> Deploy Production OK."
else
  docker run --rm \
    -e CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN" \
    -v "$OUT_DIR/public:/site:ro" \
    "$WRANGLER_IMAGE" \
    pages deploy /site --project-name "$CF_PAGES_PROJECT" --branch "$CF_BRANCH"
  echo "==> Deploy Preview OK."
fi

