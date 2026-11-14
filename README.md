# VoiceWake

Déclencheur vocal local pour macOS : dis « Salut Claude » (ou « Dis / Hey Claude »), « Salut ChatGPT », « Salut Codex » ou « Salut Gemini » : VoiceWake ouvre l'application et active son micro. Termine par « ok envoie » pour envoyer le message.

- **Gratuit et local** : reconnaissance vocale d'Apple sur le Mac, sans API ni abonnement.
- **Invisible** : pas de fenêtre ni d'icône, démarre avec la session.
- **Multi-assistants** : une phrase par application, plus une phrase générale qui vise l'application au premier plan.
- **Discret pendant la conversation** : VoiceWake libère le micro et se met en pause tant que l'assistant l'utilise.

> Projet indépendant, sans lien avec Anthropic ou OpenAI.

## Fonctionnement

```
micro → transcription locale → phrase reconnue → ouverture de l'app + raccourci
      → pause (micro libéré) tant que l'assistant parle → retour en veille
```

| Phrase | Action |
| --- | --- |
| « Salut Claude » | Claude |
| « Salut ChatGPT » | ChatGPT |
| « Salut Codex » | Codex |
| « Salut Gemini » | Gemini |
| « Salut assistant » | application au premier plan, sinon `defaultTarget` |

## Installation

Prérequis : macOS 13+, outils de compilation (`xcode-select --install`).

```bash
git clone https://github.com/RychTwins/voicewake.git
cd voicewake
./install.sh
```

Accepte ensuite les trois autorisations demandées par macOS : **Micro**, **Reconnaissance vocale** et **Accessibilité** (pour simuler le raccourci).

L'installation crée un certificat de signature local, une seule fois. Grâce à lui, macOS conserve les autorisations quand tu réinstalles une nouvelle version.

## Configuration

Fichier : `~/.config/voicewake/config.json` (copie de `config.example.json`).

### Raccourci vocal : n'importe lequel

VoiceWake rejoue le raccourci que **tu** as défini dans chaque application. Le plus simple est de l'enregistrer au clavier :

```bash
voicewake record claude    # puis tape le raccourci vocal de Claude
voicewake record codex
```

Ou de l'écrire :

```bash
voicewake set claude "capslock"
voicewake set chatgpt "option+space"
```

| Syntaxe | Exemple | Usage |
| --- | --- | --- |
| combinaison | `ctrl+shift+v`, `cmd+option+f5` | cas courant |
| touche seule | `capslock`, `fn`, `f13` | Verr. Maj. de Claude, touche globe |
| modificateur seul | `option`, `ctrl+option` | appui puis relâchement |
| double appui | `double option` | Quick Entry de Claude |
| maintien | `hold 1.5 fn` | push-to-talk |
| enchaînement | `cmd+k then v` | raccourcis en deux temps |
| code brut | `keycode:57` | touche non reconnue |

Les lettres suivent la disposition active (AZERTY, QWERTY…). Modificateurs : `ctrl`, `option`, `shift`, `cmd`, `fn`, et `rcmd`, `roption`… pour ceux de droite.

**Valeurs par défaut** (à confirmer dans chaque application) :

| App | Raccourci | Effet | À faire |
| --- | --- | --- | --- |
| Claude | `button:Maintenez appuyé pour enregistrer` | micro de la session ouverte | Rien (libellé de l'interface en français ou anglais) |
| ChatGPT | `ctrl+option+d` | Dictée macOS dans le champ actif | Régler ⌃⌥D dans Réglages Système > Clavier > Dictée |
| Codex | `button:Dicter` | micro de la zone de saisie | Vérifier le bundle ID (voir ci-dessous) |
| Gemini | `button:Utiliser le micro (⌘D)` | micro de la zone de saisie | Rien |

**Applications OpenAI récentes** : l'app installée sous le nom `ChatGPT.app` peut être l'app Codex (bundle `com.openai.codex`), et l'ancienne app ChatGPT s'appelle alors `ChatGPT Classic.app` (`com.openai.chat`). Vérifie avec `mdls -name kMDItemCFBundleIdentifier /Applications/*.app`, puis renseigne `appName` et `bundleID` de chaque cible (ex. codex → `"appName": "ChatGPT", "bundleID": "com.openai.codex"`). `voicewake check` doit afficher « installée : oui » pour chaque cible.

### Micro intégré de l'app et envoi à la voix

`"shortcut": "button:<libellé>"` clique le bouton micro de l'application (via l'Accessibilité), libellé exact, plusieurs séparés par `|`. Exemples testés (macOS en français) :

| App | `shortcut` | `stopShortcut` | `submitShortcut` |
| --- | --- | --- | --- |
| Claude | `button:Maintenez appuyé pour enregistrer` | `button:Arrêter la dictée` | `return` (défaut) |
| Codex (`ChatGPT.app`) | `button:Dicter` | `button:Arrêter la dictée` | `button:Envoyer` |
| Gemini | `button:Utiliser le micro (⌘D)` | `button:Arrêter (⌘D)` | `button:Envoyer` |
| ChatGPT Classic | `ctrl+option+d` (Dictée macOS) | idem | `return` |

ChatGPT Classic : son bouton « Dictée » ne réagit pas au clic automatique, d'où la Dictée macOS. Cette app est retirée le 30/01/2027.

Pendant la dictée, VoiceWake continue d'écouter (micro partagé). Termine par une phrase puis ~1 s de silence :

- `stopPhrases` (« ok arrête », « ok stop ») : coupe le micro de l'app pour relire ; « ok envoie » reste attendu pendant `reviewSeconds` (180).
- `sendPhrases` (« ok envoie », « c'est bon vas-y envoie ») : coupe le micro si besoin, attend `submitDelaySeconds` (1,5), puis envoie.
- `sendSilenceSeconds` (1,2) : silence requis après la phrase. Une phrase d'envoi en milieu de phrase ne déclenche rien.
- `sendPauseBeforeSeconds` (0,6) : pause requise aussi *avant* « ok envoie » / « ok arrête ». Évite l'envoi quand tu cites la phrase en parlant. `0` = désactivé.

**Lecture à voix haute automatique** : après un envoi vocal, VoiceWake attend la fin de la réponse puis clique le dernier bouton de lecture (`readAloudShortcut`, ex. `button:Lire à voix haute`). Fin de réponse = disparition des libellés `busyLabels` (Claude : « Arrêter », « Message en cours de génération ») ou apparition d'un nouveau bouton de lecture, stable 2 s. Attente max : `readAloudTimeoutSeconds` (600). Configuré pour Claude et Codex. Tant qu'une app d'assistant joue du son, les phrases d'activation sont ignorées (VoiceWake ne se déclenche pas sur la voix de lecture).

**Interrompre la lecture** : pendant la lecture, dis une phrase de `interruptPhrases` (« stop lecture », « arrête la lecture », « stop stop »). VoiceWake clique `pauseReadShortcut` (Claude : `button:Pause`), rouvre le micro de l'app, puis tu dictes ta nouvelle demande et « ok envoie ». Limite : si la réponse lue contient elle-même une phrase d'interruption, la lecture s'interrompt toute seule (pas de distinction entre ta voix et celle des haut-parleurs ; un casque évite le problème).

App fermée : VoiceWake la lance, attend `launchDelaySeconds` (3), puis cherche le bouton micro pendant 20 s maximum.

Le micro de l'app transcrit aussi « ok envoie » dans le message. Pour trouver le libellé d'un bouton : Accessibility Inspector (Xcode > Open Developer Tool).

Phrases d'activation : ajoute autant de variantes que voulu par cible (« salut claude », « dis claude », « hey claude », « say claude »…).

**Dicter dans la session ouverte (toutes applications)** : le `capslock` de Claude dicte dans la fenêtre Quick Entry, pas dans la conversation ouverte. Pour écrire directement dans le champ actif de l'application, utilise la Dictée macOS : Réglages Système > Clavier > Dictée > Raccourci > Personnaliser → `⌃⌥D`, puis `"shortcut": "ctrl+option+d"` et `"activate": true` pour chaque cible. Une cible s'ajoute librement, ex. Gemini (`"bundleID": "com.google.GeminiMacOS"`, phrase « salut gemini »).

Avec `option+space` (fenêtre compagnon, sans micro), VoiceWake ne détecte pas de conversation et reprend la veille après `startGraceSeconds`.

### Autres réglages

- `phrases` : ajoute les variantes mal transcrites (voir les logs en mode `debug`).
- `activate` : mettre l'app au premier plan avant le raccourci (`false` pour un raccourci global).

Pause pendant la conversation (`conversation`) :

| Clé | Rôle | Défaut |
| --- | --- | --- |
| `startGraceSeconds` | délai laissé à l'assistant pour ouvrir le micro | 8 |
| `idleSecondsBeforeResume` | micro libre pendant ce temps = conversation terminée | 6 |
| `maxPauseMinutes` | reprise forcée de sécurité | 30 |

Après modification : `launchctl kickstart -k gui/$(id -u)/io.github.voicewake`

## Commandes

```bash
voicewake check                 # configuration, applications trouvées, autorisations
voicewake test claude           # envoie le raccourci de Claude dans 3 s
voicewake record claude         # enregistre le raccourci tapé au clavier
voicewake set codex "ctrl+shift+v"
voicewake route "salut codex"   # quelle cible une phrase déclenche
tail -f ~/Library/Logs/voicewake.log
```

`voicewake` est installé dans `~/.local/bin` (à ajouter au `PATH` si besoin).

## Limites connues

- L'indicateur orange du micro reste allumé en veille : protection de macOS, impossible à masquer.
- Une application qui garde le micro ouvert (visio, enregistrement) prolonge la pause, jusqu'à `maxPauseMinutes`.
- `record` demande l'autorisation « Surveillance de l'entrée » pour le Terminal (une seule fois), et `test` demande l'Accessibilité pour le Terminal.
- `voicewake check` affiche l'Accessibilité de l'application qui lance la commande (Terminal), pas celle du service : vérifie le service dans le log (pas de ligne « Autoriser VoiceWake » au démarrage).
- Verr. Maj. simulé : certaines applications ne réagissent qu'à la vraie touche. Dans ce cas, choisis un autre raccourci dans l'application et enregistre-le.
- La reconnaissance locale en français dépend de la version de macOS ; sinon mettre `"requireOnDevice": false`.

## Désinstallation

```bash
./uninstall.sh            # garde la configuration
./uninstall.sh --purge    # supprime aussi la configuration et le certificat
```

## Windows (10 / 11)

Même fonctionnement et **même fichier de configuration** que sur macOS. Code dans `windows/` (C# / .NET 8). Version **non testée sur une vraie machine Windows** : vérifie avec `voicewake check` puis `voicewake test <cible>`.

```powershell
cd voicewake\windows
.\install.ps1          # compile, installe dans %LOCALAPPDATA%\VoiceWake, démarre avec la session
.\install.ps1 -Restart # après modification de la config
.\uninstall.ps1        # -Purge pour supprimer aussi la config
```

Prérequis : SDK .NET 8 (`winget install Microsoft.DotNet.SDK.8`), langue **Français** avec l'option **Reconnaissance vocale** installée, et « Autoriser les applications de bureau à accéder au micro » activé.

| macOS | Windows |
| --- | --- |
| `~/.config/voicewake/config.json` | `%APPDATA%\voicewake\config.json` |
| `~/Library/Logs/voicewake.log` | `%LOCALAPPDATA%\VoiceWake\voicewake.log` |
| Reconnaissance Apple (texte libre) | Reconnaissance Windows **sur liste fermée** : seules les phrases de la config, dites seules (petite pause avant et après), hors ligne |
| Accessibilité (`button:`) | UI Automation (`button:`, mêmes libellés) |
| Dictée macOS (`ctrl+option+d`) | Saisie vocale Windows (`win+h`) |
| `option` / `cmd` | `alt` / `win` |

Chaque cible a un bloc `windows` facultatif :

```json
"windows": { "processName": "Claude", "launch": "startmenu:Claude", "shortcut": "win+h" }
```

- `processName` : nom du processus sans `.exe` (Gestionnaire des tâches > Détails).
- `launch` : `startmenu:<nom dans le menu Démarrer>` (défaut), `shell:AppsFolder\<AUMID>` (`Get-StartApps` dans PowerShell) ou chemin d'un `.exe` (`%LOCALAPPDATA%\…` accepté).
- `shortcut`, `stopShortcut`, `submitShortcut`, `readAloudShortcut`, `pauseReadShortcut` : surcharges Windows ; sinon la valeur commune est utilisée.
- `voicewake set <cible> "…"` écrit dans le bloc `windows`, sans toucher au raccourci macOS.
- `minConfidence` (0,5) : confiance minimale de la reconnaissance Windows.

Limites Windows : `record` n'existe pas (utilise `set`) ; « micro utilisé par une autre app » est lu dans le registre (`CapabilityAccessManager`) ; les libellés des boutons et noms de processus de ChatGPT, Codex et Gemini sur Windows restent à confirmer.

## Feuille de route

- Linux (Vosk)
- Détection plus fine de la fin de conversation

## Licence

MIT
