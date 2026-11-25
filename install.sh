#!/usr/bin/env bash
# VoiceWake — installation macOS : compile, signe, installe et démarre le service.
set -euo pipefail

[[ "$(uname)" == "Darwin" ]] || { echo "macOS requis."; exit 1; }
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ]] || { echo "macOS 13 ou plus requis."; exit 1; }
command -v swiftc >/dev/null || { echo "Outils manquants : lancer « xcode-select --install »."; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="io.github.voicewake"
CERT_NAME="VoiceWake Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
APP="$HOME/Applications/VoiceWake.app"
BIN="$APP/Contents/MacOS/voicewake"
LINK="$HOME/.local/bin/voicewake"
CONFIG_DIR="$HOME/.config/voicewake"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/voicewake.log"
DOMAIN="gui/$(id -u)"

# Certificat local stable : macOS garde les autorisations d'une compilation à l'autre.
ensure_certificate() {
  if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    return 0
  fi
  echo "→ Création du certificat de signature local (une seule fois)"
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  # /usr/bin/openssl (LibreSSL) produit un .p12 que le Trousseau sait importer.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null &&
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$CERT_NAME" -passout pass:voicewake -out "$tmp/cert.p12" &&
  security import "$tmp/cert.p12" -k "$KEYCHAIN" -P voicewake -T /usr/bin/codesign >/dev/null
  local status=$?
  if [[ $status -eq 0 ]]; then
    echo "  macOS peut demander ton mot de passe pour faire confiance au certificat."
    security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem" ||
      echo "  (Confiance refusée : la signature reste stable, ce n'est pas bloquant.)"
  fi
  rm -rf "$tmp"
  return $status
}

echo "→ Compilation"
mkdir -p "$APP/Contents/MacOS" "$(dirname "$LINK")" "$CONFIG_DIR" "$(dirname "$PLIST")" "$(dirname "$LOG")"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
swiftc -target "$(uname -m)-apple-macosx13.0" -O -swift-version 5 "$ROOT"/src/*.swift -o "$BIN" \
  -framework AppKit -framework AVFoundation -framework Speech -framework CoreAudio -framework CoreML -framework FoundationModels

echo "→ Signature"
if ensure_certificate; then
  codesign --force --sign "$CERT_NAME" --identifier "$LABEL" "$APP"
else
  echo "  Certificat impossible à créer : signature temporaire (macOS redemandera les autorisations après chaque mise à jour)."
  codesign --force --sign - --identifier "$LABEL" "$APP"
fi

echo "→ Configuration"
if [[ ! -f "$CONFIG_DIR/config.json" ]]; then
  # Configuration d'exemple dans la langue du Mac si elle existe (config.example.en.json…), sinon en français.
  SYSTEM_LANG="$(defaults read -g AppleLocale 2>/dev/null | cut -c1-2)"
  EXAMPLE="$ROOT/config.example.$SYSTEM_LANG.json"
  [[ -f "$EXAMPLE" ]] || EXAMPLE="$ROOT/config.example.json"
  cp "$EXAMPLE" "$CONFIG_DIR/config.json"
  echo "  Créée : $CONFIG_DIR/config.json ($(basename "$EXAMPLE"))"
else
  echo "  Conservée : $CONFIG_DIR/config.json"
fi
ln -sf "$BIN" "$LINK"

echo "→ Démarrage automatique"
sed -e "s|__BIN__|$BIN|g" -e "s|__LOG__|$LOG|g" "$ROOT/packaging/launchagent.plist" > "$PLIST"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout est asynchrone : on réessaie le temps que l'ancien service s'arrête.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break
  sleep 1
done
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || { echo "Échec du démarrage du service."; exit 1; }

cat <<EOF

✓ VoiceWake installé.
  1. Accepte les demandes : Micro, Reconnaissance vocale, Accessibilité (VoiceWake).
  2. Règle les raccourcis : $CONFIG_DIR/config.json
     puis : launchctl kickstart -k $DOMAIN/$LABEL
  3. Teste un raccourci : $LINK test claude
  Logs : tail -f $LOG
EOF
