#!/usr/bin/env bash
# Usage : bash tests/route.sh /chemin/vers/voicewake
set -euo pipefail

binary=${1:?Indiquer le chemin vers le binaire voicewake}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
count=0

expect_route() {
    local phrase=$1 expected=$2 actual
    actual=$("$binary" route "$phrase" --config "$root/config.example.json")
    if [[ "$actual" != "$expected" ]]; then
        printf 'Échec pour « %s »\nAttendu : %s\nObtenu : %s\n' "$phrase" "$expected" "$actual" >&2
        exit 1
    fi
    count=$((count + 1))
}

expect_route 'Salut Claude !' '→ claude'
expect_route 'Hé, Claude !' '→ claude'
expect_route 'Salut ChatGPT' '→ chatgpt'
expect_route 'Salut, Chat GPT !' '→ chatgpt'
expect_route 'Salut Codex' '→ codex'
expect_route 'Salut Gemini' '→ gemini'
expect_route 'Dis Claudeville' '→ aucune cible'
expect_route 'Bonjour le monde' '→ aucune cible'
expect_route 'Le Chromebook envoie' '→ aucune cible'
expect_route 'Le Chromebook arrête' '→ aucune cible'
expect_route 'Ok envoie ceci demain' '→ aucune cible'
expect_route 'OK, envoie !' $'→ aucune cible\n→ phrase d\'envoi (pendant une dictée)'
expect_route 'Voici ma demande. OK, ARRÊTE !' $'→ aucune cible\n→ phrase d\'arrêt du micro (pendant une dictée)'
expect_route 'Voici ma demande. Vas-y, envoie !' $'→ aucune cible\n→ phrase d\'envoi (pendant une dictée)'

printf '%s scénarios de routage réussis.\n' "$count"
