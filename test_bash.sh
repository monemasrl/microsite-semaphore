#!/usr/bin/env bash
set -euo pipefail

# I parametri sono passati come var1=val1 var2=val2 ... al comando di esecuzione dello script (es: via API o survey vars).

for arg in "$@"; do
  KEY="${arg%%=*}"
  VALUE="${arg#*=}"
  declare -A args
  args["$KEY"]="$VALUE"

  echo "Parsed argument: $KEY=$VALUE"
done

