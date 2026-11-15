#!/bin/bash
set -euo pipefail

project=${1:?Dossier du projet requis}
git_at_project() {
  /usr/bin/git -C "$project" -c core.fsmonitor=false "$@"
}

if ! status="$(git_at_project status --porcelain --no-renames 2>/dev/null)"; then
  echo "Impossible de lire l’état du dépôt Git."
  exit 1
fi
branch="$(git_at_project symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'HEAD détachée')"
if [[ -z "$status" ]]; then
  changes="Aucun fichier modifié."
else
  count="$(printf '%s\n' "$status" | /usr/bin/awk 'END { print NR }')"
  changes="$count fichier(s) modifié(s) ou non suivi(s)."
fi
commit="$(git_at_project rev-parse --short HEAD 2>/dev/null || true)"
if [[ -n "$commit" ]]; then
  printf 'Branche %s. %s Dernier commit : %s.\n' "$branch" "$changes" "$commit"
else
  printf 'Branche %s. %s Aucun commit.\n' "$branch" "$changes"
fi
