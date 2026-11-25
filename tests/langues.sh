#!/usr/bin/env bash
# Usage : bash tests/langues.sh /chemin/vers/voicewake
# Chaque pack de langue fourni : complet, et sa configuration de départ appelle bien les assistants.
set -euo pipefail

binary=${1:?Indiquer le chemin vers le binaire voicewake}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
example="$root/config.example.json"
tmp="$(mktemp -d -t voicewake-langues)"
trap 'rm -rf "$tmp"' EXIT
count=0

fail() { printf '%s\n' "$1" >&2; exit 1; }

for file in "$root"/src/Lang+*.swift; do
    code="$(basename "$file" .swift)"; code="${code#Lang+}"
    "$binary" langue "$code" --config "$example" > "$tmp/$code.txt" || { cat "$tmp/$code.txt" >&2; fail "Pack « $code » incomplet."; }
    config="$tmp/$code.json"
    "$binary" exemple "$code" --config "$example" > "$config" || fail "Configuration « $code » non produite."
    "$binary" check --config "$config" > /dev/null || fail "Configuration « $code » refusée."
    # Chaque assistant répond à sa première phrase d'appel, et à aucun autre.
    while IFS=$'\t' read -r id phrase; do
        got="$("$binary" route "$phrase" --config "$config" | head -1)"
        [[ "$got" == "→ $id" ]] || fail "« $code » : « $phrase » donne « $got », attendu « → $id »."
        count=$((count + 1))
    done < <(python3 -c '
import json, sys
for t in json.load(open(sys.argv[1]))["targets"]:
    print(t["id"] + "\t" + t["phrases"][0])' "$config")
    # La première phrase d'envoi et la première phrase d'arrêt sont reconnues.
    for key in sendPhrases stopPhrases; do
        phrase="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][0])' "$config" "$key")"
        "$binary" route "$phrase" --config "$config" | grep -q "pendant une dictée" || fail "« $code » : « $phrase » ($key) non reconnue."
        count=$((count + 1))
    done
    # Une langue à la fois : le français n'appelle plus personne.
    [[ "$("$binary" route "Dis Claude" --config "$config" | head -1)" == "→ aucune cible" ]] || fail "« $code » : « Dis Claude » encore compris."
    count=$((count + 1))
    echo "$code : pack complet, configuration valide"
done

echo "$count vérifications de langues réussies."
