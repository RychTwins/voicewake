# VoiceWake

**Pilotez Claude, Codex, Gemini et ChatGPT à la voix, sans toucher au clavier.**

Dites « Dis Claude » : VoiceWake ouvre l'application, active son micro intégré, vous dictez votre demande, puis « OK envoie » l'envoie. La réponse est ensuite lue à voix haute. Le tout fonctionne aussi dans VS Code et les éditeurs dérivés.

- **Local et gratuit** : reconnaissance vocale d'Apple exécutée sur le Mac, sans API ni abonnement.
- **Invisible** : un service en arrière-plan, sans fenêtre ni icône, lancé à l'ouverture de session.
- **Contextuel** : la fenêtre au premier plan décide. Dans VS Code, « Dis Claude » vise l'extension Claude Code ; ailleurs, l'application Claude.
- **Mains libres de bout en bout** : activation, dictée, envoi, lecture de la réponse et interruption de la lecture.

- **Sans interface** : tout s'installe et se règle en ligne de commande.

> **Open source et gratuit.** Téléchargez-le, testez-le sur votre Mac, améliorez-le et adaptez-le à votre façon de travailler. La version actuelle est en **français** ; elle s'adapte à n'importe quelle langue (voir [Adapter à votre langue](#adapter-à-votre-langue)). Les contributions sont les bienvenues.

> Projet indépendant, sans lien avec Anthropic, OpenAI ou Google.

---

## Sommaire

1. [Démarrage rapide](#démarrage-rapide)
2. [Commandes vocales](#commandes-vocales)
3. [Applications prises en charge](#applications-prises-en-charge)
4. [Éditeurs de code](#éditeurs-de-code)
5. [Configuration](#configuration)
6. [Application de dictée externe](#application-de-dictée-externe)
7. [Commandes du terminal](#commandes-du-terminal)
8. [Dépannage](#dépannage)
9. [Limites connues](#limites-connues)
10. [Windows](#windows)
11. [Désinstallation](#désinstallation)
12. [Adapter à votre langue](#adapter-à-votre-langue)
13. [Contribuer](#contribuer)

---

## Démarrage rapide

**Prérequis** : macOS 13 ou plus récent, outils de compilation Apple (`xcode-select --install`).

```bash
git clone https://github.com/RychTwins/voicewake.git
cd voicewake
./install.sh
```

1. Acceptez les trois autorisations demandées par macOS : **Micro**, **Reconnaissance vocale** et **Accessibilité** (VoiceWake clique les boutons des applications).
2. Vérifiez l'installation : `voicewake check`.
3. Ouvrez Claude et dites « **Dis Claude** », puis votre demande, puis « **OK envoie** ».

`install.sh` compile le programme, le signe avec un certificat local créé une seule fois (macOS conserve ainsi les autorisations d'une version à l'autre), installe `~/Applications/VoiceWake.app`, crée la configuration et démarre le service. La commande `voicewake` est installée dans `~/.local/bin`.

---

## Commandes vocales

Chaque commande se dit **seule**, avec une courte pause avant et environ une seconde de silence après.

### Activer un assistant

| Phrase | Effet |
| --- | --- |
| « Dis Claude », « Salut Claude », « Hey Claude » | micro de Claude |
| « Dis Codex », « Salut Codex » | micro de Codex |
| « Dis Gemini », « Salut Gemini » | micro de Gemini |
| « Salut ChatGPT » | dictée dans ChatGPT |
| « Salut assistant », « Dis assistant » | assistant de l'application au premier plan, sinon `defaultTarget` |

L'application est lancée si elle est fermée, puis mise au premier plan. VoiceWake attend le résultat définitif de la reconnaissance (environ une seconde après la fin de la phrase) avant d'agir : le moteur corrige souvent sa première hypothèse, par exemple « Salut Claude » en « Salut Codex ». « Salut … » est la forme la mieux reconnue.

Pendant une dictée, une phrase d'activation dite seule (« Salut Gemini ») arrête la dictée en cours sans l'envoyer et ouvre l'autre assistant.

### Pendant la dictée

| Phrase | Effet |
| --- | --- |
| « OK envoie », « OK tu peux envoyer », « Vas-y, envoie », « Bon, tu envoies »… | coupe le micro, laisse le texte s'afficher, puis envoie |
| « OK arrête », « OK stop », « Annule », « Laisse tomber » | coupe seulement le micro, sans envoyer ; dites ensuite « OK envoie » pour envoyer quand même (3 min max) |
| 5 s de silence après avoir parlé | envoie, si `"autoSendSilenceSeconds": 5` est réglé (désactivé par défaut) |

Gardez l'application au premier plan jusqu'à l'envoi : si une autre application passe devant, l'envoi est annulé.

### Pendant la lecture à voix haute

Après un envoi vocal, VoiceWake attend la fin de la réponse puis lance la lecture à voix haute.

| Phrase | Effet |
| --- | --- |
| « Arrête la lecture », « Stop la lecture » | pause |
| « Reprends la lecture », « Continue la lecture » | reprise là où elle s'était arrêtée (10 min max) ; sans lecture en pause, lit la dernière réponse |
| « Écoute » | pause et micro rouvert pour une nouvelle demande |
| « Fais la lecture », « Lis la réponse », « Relis la réponse » | en veille : lit la dernière réponse de l'assistant au premier plan, même ancienne (bouton de lecture de l'application) |

| « Lis à partir de … » suivi de quelques mots du passage | le lecteur intégré reprend la lecture à cet endroit |

La voix de lecture ne déclenche pas ses propres commandes : une commande entendue pendant une lecture est ignorée si le texte affiché par l'assistant la contient, précédée du même mot. Pendant une lecture lancée par VoiceWake, les phrases d'activation sont ignorées.

**Suivi de la lecture** : pendant la lecture à voix haute d'une application (lancée par VoiceWake), un bandeau en bas de l'écran affiche le passage en cours, mot surligné. VoiceWake suit la lecture en l'écoutant au micro : il faut donc que le son sorte des haut-parleurs (pas d'un casque), et l'affichage a une à deux secondes de retard. À activer avec `"showReadingProgress": true` (désactivé par défaut : le bandeau affiche à l'écran le texte de la réponse). Une commande ignorée parce qu'attribuée à la voix de lecture passe si vous la redites dans les 6 secondes (à la troisième fois au plus tard).

**Surlignage dans l'application (expérimental, peu fiable)** : le suivi à l'oreille décroche souvent en conditions réelles ; désactivé par défaut.  avec `"highlightReadingInApp": true`, VoiceWake pose un rectangle jaune transparent sur le bloc de texte en cours de lecture, directement dans la réponse de l'assistant, et fait défiler la conversation pour le garder visible. Il fonctionne aussi pour une lecture lancée à la main. Par bloc de texte, pas mot par mot. Vérifier sans lecture : `voicewake highlight claude "quelques mots visibles"`.

**Lecteur intégré** : les applications ne savent pas démarrer leur lecture au milieu d'une réponse. « Lis à partir de … » fait donc lire le texte affiché par VoiceWake lui-même, avec une voix du Mac, depuis la dernière occurrence des mots cités (deux mots au moins, petites différences tolérées). Un bandeau en bas de l'écran affiche le passage en cours, mot prononcé surligné. « Arrête la lecture », « Reprends la lecture » et « Écoute » s'appliquent aussi à ce lecteur. Pour une meilleure voix : Réglages Système > Accessibilité > Contenu énoncé > Voix du système > Gérer les voix (voix « Premium » ou « Améliorée »), ou `"readerVoice": "Thomas"`. Vérifier sans parler : `voicewake passage claude "quelques mots"`.

---

### Conversation continue

Avec `"continuousConversation": true`, VoiceWake envoie la dictée après 5 s de silence dès qu'il détecte de la parole et que le bouton d'envoi est disponible. Réglez le délai avec `autoSendSilenceSeconds` (`0` désactive l'envoi automatique).

- **« Attends, je réfléchis »** suspend l'envoi jusqu'à ce que vous repreniez la parole.
- **« Garde le brouillon »** ou **« OK arrête »** coupe le micro et laisse le texte dans le composeur.

Le micro se rouvre dans la même fenêtre après la lecture de la réponse. Si aucune lecture n'est configurée, VoiceWake attend que le texte de la fenêtre se stabilise pendant 6 s. Après une réouverture sans parole pendant `continueSilenceSeconds` (10 s par défaut), le micro se referme et VoiceWake repasse en veille.

Sans casque, la voix de lecture peut laisser un écho : la reprise attend 3 s de silence après la fin de la lecture.

### Voix ElevenLabs (optionnel)

Par défaut, VoiceWake n'appelle aucun service en ligne. Si vous avez un compte ElevenLabs, vous pouvez remplacer la voix du Mac pour « lis à partir de… » :

```json
"elevenLabs": { "enabled": true, "voiceID": "JBFqnCBsd6RMkjVDRZzb", "model": "eleven_flash_v2_5" }
```

Placez la clé dans `~/.config/voicewake/elevenlabs.env` (une ligne `ELEVENLABS_API_KEY=…`, droits `600`), jamais dans la configuration ni dans le dépôt. Le texte à dire est alors envoyé à ElevenLabs et compte dans votre quota. En cas d'erreur, la voix du Mac prend le relais. Claude, Gemini et Codex gardent leur propre voix.

## Applications prises en charge

| Application | Micro | Envoi | Lecture à voix haute | État |
| --- | --- | --- | --- | --- |
| **Claude** | bouton micro intégré | Entrée | oui, avec pause et reprise | testé à la voix |
| **Codex** (`ChatGPT.app`) | raccourci `cmd+shift+d` | bouton « Envoyer » | oui | testé à la voix |
| **Gemini** | bouton micro intégré | bouton « Envoyer » | oui (menu « Autres actions » > « Écouter »), avec pause et reprise | activation et envoi testés à la voix |
| **ChatGPT Classic** | Dictée macOS (`ctrl+option+d`) | Entrée | non | testé |
| **VS Code** + Claude Code | bouton « Voice dictation » | bouton « Send message » | non | testé sans la voix |
| **VS Code** + Codex | bouton « Dicter » | bouton « Envoyer » | non | testé sans la voix |
| Cursor, Antigravity, Windsurf | comme VS Code | comme VS Code | non | configurés, non testés |

Les libellés des boutons correspondent à une interface en français ; les libellés anglais sont prévus en alternative.

**Applications OpenAI récentes** : sur certains Mac, `ChatGPT.app` est l'application Codex (`com.openai.codex`) et l'ancienne application s'appelle `ChatGPT Classic.app` (`com.openai.chat`). La configuration d'exemple identifie donc ces deux cibles par leur `bundleID`. Pour vérifier : `mdls -name kMDItemCFBundleIdentifier /Applications/*.app`.

**ChatGPT Classic** : son bouton « Dictée » ne réagit pas au clic automatique, d'où l'usage de la Dictée macOS. Réglez son raccourci dans **Réglages Système > Clavier > Dictée > Raccourci > Personnaliser** → `⌃⌥D`. Cette application est retirée le 30 janvier 2027.

---

## Éditeurs de code

Règle : **la fenêtre au premier plan décide**.

- Un éditeur de la liste `editors` est au premier plan et intègre l'assistant appelé : le micro s'ouvre **dans l'éditeur**.
- Autre fenêtre au premier plan, ou panneau de l'assistant fermé dans l'éditeur : l'application de bureau prend le relais.
- « Salut assistant » dans un éditeur vise `preferredAssistant`, sinon `defaultTarget`.

```json
"editors": [{
  "id": "vscode",
  "bundleIDs": ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.google.antigravity"],
  "preferredAssistant": "codex",
  "assistants": {
    "claude": { "shortcut": "button:Voice dictation", "stopShortcut": "button:Stop recording", "submitShortcut": "button:Send message" },
    "codex":  { "shortcut": "button:Dicter|Dictate", "stopShortcut": "button:Arrêter la dictée|Stop dictation", "submitShortcut": "button:Envoyer|Send" }
  }
}]
```

`voicewake test claude` applique la même règle : passez sur l'éditeur pendant le compte à rebours de 3 secondes.

---

## Configuration

Fichier : `~/.config/voicewake/config.json`, créé à partir de [`config.example.json`](config.example.json). Après modification :

```bash
launchctl kickstart -k gui/$(id -u)/io.github.voicewake
```

### Réglages généraux

| Clé | Rôle | Défaut |
| --- | --- | --- |
| `locale` | langue de reconnaissance | `fr-FR` |
| `requireOnDevice` | reconnaissance exclusivement locale | `true` |
| `cooldownSeconds` | délai minimal entre deux activations | `5` |
| `debug` | écrit les transcriptions dans le log | `false` |
| `dryRun` | essai à blanc : journalise la cible reconnue sans rien ouvrir, pour régler les phrases | `false` |
| `wakeMaxWaitSeconds` | attente maximale du résultat définitif avant d'agir | `1.8` |
| `echoCancellation` | annulation d'écho de macOS (expérimental : peut empêcher la reconnaissance de votre voix) | `false` |
| `defaultTarget` | cible de « Salut assistant » hors application connue | `claude` |
| `frontmostPhrases` | phrases visant l'application au premier plan | « salut assistant »… |
| `sendPhrases`, `stopPhrases` | commandes d'envoi et d'arrêt pendant la dictée | voir l'exemple |
| `sendSilenceSeconds` | silence requis après une commande | `1.2` |
| `sendPauseBeforeSeconds` | pause requise avant une commande (`0` pour désactiver) | `0.6` |
| `reviewSeconds` | attente de « OK envoie » après « OK arrête » | `180` |
| `readPausePhrases`, `readResumePhrases`, `interruptPhrases` | commandes pendant la lecture | voir l'exemple |
| `readFromPhrases`, `readerVoice` | « lis à partir de … » et voix du lecteur intégré | voir l'exemple |
| `conversation.startGraceSeconds` | délai laissé à l'application pour ouvrir son micro | `8` |
| `conversation.idleSecondsBeforeResume` | micro libre pendant ce délai = conversation terminée | `6` |
| `conversation.maxPauseMinutes` | retour forcé en veille | `30` |

### Réglages par application (`targets`)

| Clé | Rôle |
| --- | --- |
| `id`, `appName`, `bundleID` | identification de l'application (le `bundleID` est prioritaire) |
| `phrases` | phrases d'activation ; ajoutez les variantes mal transcrites (voir `debug`) |
| `shortcut` | ouverture du micro |
| `stopShortcut` | arrêt du micro (défaut : `shortcut`) |
| `submitShortcut` | envoi (défaut : `return`) |
| `readAloudShortcut`, `readAloudMenuItem` | bouton de lecture à voix haute, et option de menu s'il ouvre un menu |
| `pauseReadShortcut`, `resumeReadShortcut` | pause et reprise de la lecture |
| `busyLabels` | libellés visibles tant que l'assistant répond |
| `activate`, `launchDelaySeconds` | mise au premier plan, attente après un lancement (`3` s) |
| `windows` | réglages propres à Windows (voir [Windows](#windows)) |

### Syntaxe des raccourcis

| Forme | Exemple | Usage |
| --- | --- | --- |
| bouton de l'application | `button:Dicter\|Dictate` | clic par l'Accessibilité, libellé exact, alternatives séparées par `\|` |
| combinaison | `ctrl+shift+v`, `cmd+shift+d` | cas courant |
| touche seule | `capslock`, `fn`, `f13` | touche dédiée |
| double appui | `double option` | raccourcis à double appui |
| maintien | `hold 1.5 fn` | push-to-talk |
| enchaînement | `cmd+k then v` | raccourcis en deux temps |
| code brut | `keycode:57` | touche non reconnue |

Les lettres suivent la disposition active (AZERTY, QWERTY…). Modificateurs : `ctrl`, `option`, `shift`, `cmd`, `fn`, et `rcmd`, `roption`… pour ceux de droite. Les libellés des boutons se relèvent avec **Accessibility Inspector** (Xcode > Open Developer Tool).

---

## Application de dictée externe

Pour utiliser Whisper, SuperWhisper, MacWhisper, Wispr Flow, VoiceInk ou un outil équivalent à la place des micros intégrés, configurez dans cet outil un raccourci global qui insère le texte dans le champ actif, puis :

```json
"externalDictation": {
  "shortcut": "ctrl+option+space",
  "stopShortcut": "ctrl+option+space"
}
```

- Ce raccourci remplace le micro de toutes les applications. `null` rétablit les micros intégrés.
- Les phrases nominatives (« Dis Claude ») ouvrent l'application de bureau. Dans un éditeur, « Salut assistant » dicte dans le champ déjà actif.
- « OK arrête » termine la dictée ; l'envoi se fait ensuite manuellement.
- Outil à maintien : `"shortcut": "hold 3 fn"`, sans `stopShortcut`.
- Dictée macOS par le menu Édition : `"useMacOSDictationMenu": true`, sans `stopShortcut`.
- Si le curseur n'est pas placé dans le bon champ : `"dictationFieldLabels": ["libellé exact du champ"]` dans la cible concernée.

---

## Commandes du terminal

```bash
voicewake check                    # configuration, applications trouvées, autorisations
voicewake test claude              # déclenche Claude dans 3 s, sans la voix
voicewake route "dis claude"       # cible ou commande associée à une phrase
voicewake set codex "cmd+shift+d"  # change le raccourci d'une cible
voicewake record claude            # enregistre un raccourci tapé au clavier
tail -f ~/Library/Logs/voicewake.log
```

---

## Dépannage

Le journal `~/Library/Logs/voicewake.log` indique chaque étape. Pour y voir aussi les transcriptions, passez `"debug": true` puis relancez le service.

| Message ou symptôme | Cause probable | Solution |
| --- | --- | --- |
| Rien dans le log quand vous parlez | phrase transcrite autrement | activez `debug`, puis ajoutez la variante dans `phrases` |
| « Phrase ignorée : lecture à voix haute … en cours » | une lecture est en cours | dites « Arrête la lecture » ou « Écoute » |
| « bouton introuvable » | panneau fermé, interface dans une autre langue ou libellé modifié | ouvrez le panneau ; vérifiez le libellé avec Accessibility Inspector |
| « envoi annulé » | une autre application est passée au premier plan | gardez l'application devant jusqu'à l'envoi |
| « OK envoie » sans effet | `externalDictation` actif ou `sendPhrases` vide | remettez `"externalDictation": null` et la liste `sendPhrases` |
| Dictée macOS au lieu du micro de l'application | `externalDictation` actif | `"externalDictation": null` |
| « Autoriser VoiceWake » au démarrage | Accessibilité refusée | Réglages Système > Confidentialité et sécurité > Accessibilité |
| « impossible de mettre l'app au premier plan » | écran verrouillé, ou une fenêtre système au premier plan | déverrouillez le Mac |
| « Modèle vocal fr-FR pas encore prêt » | juste après le démarrage du Mac | rien à faire, VoiceWake réessaie toutes les 5 s |

`voicewake check` affiche l'Accessibilité de l'application qui lance la commande (le Terminal), pas celle du service : pour le service, fiez-vous au log. Évitez de faire modifier la configuration par un autre outil pendant une dictée : chaque redémarrage du service interrompt la dictée en cours.

---

## Limites connues

- L'indicateur orange du micro reste allumé en veille : protection de macOS.
- La commande d'envoi est aussi transcrite par le micro de l'application et apparaît en fin de message.
- Le lecteur intégré lit le texte affiché à l'écran : une réponse ancienne, que l'application n'affiche plus, n'est pas retrouvée.
- Une application qui garde le micro ouvert (visio, enregistrement) prolonge la pause jusqu'à `maxPauseMinutes`.
- Codex : « Arrête la lecture » arrête la lecture (pas de pause dans l'application) ; « Reprends la lecture » la relance depuis le début. Son bouton de lecture demande un vrai clic : VoiceWake déplace brièvement le pointeur, puis le remet en place.
- Les libellés des boutons dépendent de la langue et des versions des applications.
- `record` demande l'autorisation « Surveillance de l'entrée » pour le Terminal ; `test` demande l'Accessibilité pour le Terminal.
- La reconnaissance locale en français dépend de la version de macOS ; à défaut, `"requireOnDevice": false`.

---

## Windows

> **Version préliminaire, non testée sur une machine Windows.**

Même fonctionnement et même fichier de configuration. Code dans [`windows/`](windows) (C# / .NET 8).

```powershell
cd voicewake\windows
.\install.ps1           # compile, installe dans %LOCALAPPDATA%\VoiceWake, démarre avec la session
.\install.ps1 -Restart  # après modification de la configuration
```

**Prérequis** : SDK .NET 8 (`winget install Microsoft.DotNet.SDK.8`), langue **Français** avec l'option **Reconnaissance vocale**, et « Autoriser les applications de bureau à accéder au micro » activé.

| macOS | Windows |
| --- | --- |
| `~/.config/voicewake/config.json` | `%APPDATA%\voicewake\config.json` |
| `~/Library/Logs/voicewake.log` | `%LOCALAPPDATA%\VoiceWake\voicewake.log` |
| reconnaissance Apple, texte libre | reconnaissance Windows sur liste fermée, hors ligne |
| Accessibilité (`button:`) | UI Automation (`button:`, mêmes libellés) |
| Dictée macOS (`ctrl+option+d`) | saisie vocale Windows (`win+h`) |
| `option`, `cmd` | `alt`, `win` |

Bloc `windows` facultatif par cible :

```json
"windows": { "processName": "Claude", "launch": "startmenu:Claude", "shortcut": "win+h" }
```

- `processName` : nom du processus sans `.exe`.
- `launch` : `startmenu:<nom>` (défaut), `shell:AppsFolder\<AUMID>` ou chemin d'un `.exe`.
- `shortcut`, `stopShortcut`, `submitShortcut`, `readAloudShortcut`, `pauseReadShortcut` : surcharges propres à Windows.
- `minConfidence` (`0.5`) : confiance minimale de la reconnaissance.

Non pris en charge sous Windows pour l'instant : `record`, éditeurs de code, commandes de lecture.

---

## Désinstallation

```bash
./uninstall.sh            # conserve la configuration
./uninstall.sh --purge    # supprime aussi la configuration et le certificat
```

Windows : `.\uninstall.ps1` (`-Purge` pour supprimer aussi la configuration).

---

## Adapter à votre langue

Seule la configuration change, le code reste identique :

1. `locale` : votre langue de reconnaissance, par exemple `en-US`, `es-ES`, `de-DE`, `pt-BR`.
2. `phrases`, `frontmostPhrases`, `sendPhrases`, `stopPhrases`, `readPausePhrases`, `readResumePhrases`, `interruptPhrases` : vos commandes dans cette langue (« Hey Claude », « OK send »…).
3. Les libellés `button:` suivent la langue de l'interface des applications : relevez-les avec Accessibility Inspector, ou ajoutez-les en alternative avec `|` (`button:Envoyer|Send`).
4. Relancez le service, puis vérifiez avec `voicewake route "hey claude"`.

Si votre langue n'est pas reconnue localement par macOS, passez `"requireOnDevice": false`.

---

## Contribuer

Le projet est ouvert à tous : nouvelles langues, nouveaux assistants, autres éditeurs, version Linux, corrections.

1. Forkez le dépôt et créez une branche.
2. Vérifiez vos changements : `./install.sh`, `voicewake check`, puis `bash tests/route.sh ~/.local/bin/voicewake`.
3. Ouvrez une pull request en décrivant ce que vous avez testé (application, langue, version de macOS).

Un bug ou une idée ? Ouvrez une [issue](https://github.com/RychTwins/voicewake/issues) avec l'extrait utile du journal `~/Library/Logs/voicewake.log` (en mode `debug`, il contient vos paroles : relisez-le avant de le partager).

---

## Feuille de route

- Version Linux (Vosk)
- Lecture à voix haute dans les éditeurs de code
- Version anglaise de la documentation
- Configurations prêtes à l'emploi pour d'autres langues

## Licence

[MIT](LICENSE)
