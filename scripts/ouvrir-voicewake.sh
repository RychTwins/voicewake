#!/bin/bash
set -euo pipefail

project=${1:?Dossier du projet requis}
if [[ ! -d "$project" ]]; then
  echo "Le dossier du projet est introuvable."
  exit 1
fi
project="$(cd -- "$project" && pwd -P)"

if ! /usr/bin/open -b com.microsoft.VSCode "$project" 2>/dev/null; then
  echo "Impossible d’ouvrir le projet dans VS Code."
  exit 1
fi
if ! /usr/bin/open -b com.apple.Terminal "$project" 2>/dev/null; then
  echo "Projet ouvert dans VS Code. Impossible d’ouvrir le Terminal."
  exit 1
fi
echo "Projet ouvert dans VS Code et dans le Terminal."
