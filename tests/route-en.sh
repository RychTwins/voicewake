#!/usr/bin/env bash
# Usage : bash tests/route-en.sh /chemin/vers/voicewake
# Routage en anglais (config.example.en.json, pack de langue « en »).
set -euo pipefail

binary=${1:?Indiquer le chemin vers le binaire voicewake}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$root/config.example.en.json"
count=0

expect_route() {
    local phrase=$1 expected=$2 actual
    actual=$("$binary" route "$phrase" --config "$config")
    if [[ "$actual" != "$expected" ]]; then
        printf 'Échec pour « %s »\nAttendu : %s\nObtenu : %s\n' "$phrase" "$expected" "$actual" >&2
        exit 1
    fi
    count=$((count + 1))
}

expect_route 'Hey Claude' '→ claude'
expect_route 'Hi, Codex!' '→ codex'
expect_route 'Hello Gemini' '→ gemini'
expect_route 'Claude' '→ claude'
expect_route 'Hello world' '→ aucune cible'
expect_route 'I asked Claude about it yesterday' '→ aucune cible'
expect_route 'OK, send it' $'→ aucune cible\n→ phrase d\'envoi (pendant une dictée)'
expect_route 'I will send the file tomorrow' '→ aucune cible'
expect_route 'OK stop' $'→ aucune cible\n→ phrase d\'arrêt du micro (pendant une dictée)'
expect_route 'Next session' $'→ aucune cible\n→ navigation : Session suivante'
expect_route 'Open settings' $'→ aucune cible\n→ navigation : Paramètres…'
expect_route 'Open VoxTV' $'→ aucune cible\n→ ouvrir : voxtv'
expect_route 'New session in VoxTV' $'→ aucune cible\n→ nouvelle session dans : voxtv'
expect_route 'Where are we?' $'→ aucune cible\n→ commande : status'
expect_route 'Copy the answer' $'→ aucune cible\n→ commande : copyResponse'
expect_route 'New chat' $'→ aucune cible\n→ commande : newChat'
expect_route 'Write hello there' $'→ aucune cible\n→ écris : « hello there »'
# Le français n'est plus compris quand la langue est l'anglais : une seule langue à la fois.
expect_route 'Dis Claude' '→ aucune cible'
expect_route 'Session suivante' '→ aucune cible'

# Le pack fourni couvre tout l'inventaire de la langue source.
"$binary" langue en --config "$config" >/dev/null || { echo "Pack anglais incomplet : voicewake langue en" >&2; exit 1; }
count=$((count + 1))

echo "$count scénarios de routage anglais réussis."
