#!/usr/bin/env bash
# VoiceWake — désinstallation. --purge supprime aussi la configuration et le certificat.
set -euo pipefail

LABEL="io.github.voicewake"
CERT_NAME="VoiceWake Local Signing"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/voicewake"
rm -rf "$HOME/Applications/VoiceWake.app"
tccutil reset All "$LABEL" >/dev/null 2>&1 || true

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/.config/voicewake" "$HOME/Library/Logs/voicewake.log"
  security delete-identity -c "$CERT_NAME" >/dev/null 2>&1 || true
  echo "✓ VoiceWake, sa configuration et son certificat supprimés."
else
  echo "✓ VoiceWake désinstallé (configuration conservée ; --purge pour tout supprimer)."
fi
