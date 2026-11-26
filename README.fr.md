# VoiceWake

🇫🇷 **Français** · 🇬🇧 [English](README.md)

**Travaillez avec Claude, Codex et Gemini à la voix, sans toucher au clavier.**

Vous dites « Dis Claude », vous parlez, votre message part, et la réponse vous est lue à voix haute. Gratuit, open source, pour Mac.

## Comment ça marche

1. Vous dites « **Dis Claude** » : le micro de l'assistant s'ouvre.
2. Vous parlez normalement.
3. Vous vous taisez, ou vous dites « **OK envoie** » : le message part.
4. La réponse est lue à voix haute.
5. Le micro se rouvre : la conversation continue.

## Installation

### Mac

Il faut macOS 13 ou plus récent et les outils d'Apple (`xcode-select --install`).

```bash
git clone https://github.com/RychTwins/voicewake.git
cd voicewake
./install.sh
```

Acceptez les trois autorisations demandées (Micro, Reconnaissance vocale, Accessibilité), ouvrez Claude et dites « Dis Claude ».

### Windows

Il faut Windows 10 ou 11 et le SDK .NET 8 (`winget install Microsoft.DotNet.SDK.8`). Dans PowerShell :

```powershell
git clone https://github.com/RychTwins/voicewake.git
cd voicewake\windows
.\install.ps1
```

Version préliminaire, pas encore testée sur une vraie machine : voir les [prérequis Windows](docs/guide.md#windows).

## Les commandes à connaître

| Vous dites | Ce qui se passe |
| --- | --- |
| « Dis Claude », « Dis Codex », « Dis Gemini » | le micro de l'assistant s'ouvre |
| « OK envoie » | le message part |
| « OK arrête » | le micro se coupe, rien n'est envoyé |
| « Arrête la lecture », « Reprends la lecture » | pause et reprise de la lecture |
| « Écoute » | coupe la lecture et rouvre le micro |
| « Nouvelle conversation » | nouveau chat |
| « Ouvre *nom du projet* » | ouvre ce projet |
| « Clique sur *nom du bouton* » | clique ce bouton |

Il y en a beaucoup d'autres : voir le [guide complet](docs/guide.md#commandes-vocales).

## Ce qu'il sait faire

- **Vos assistants** : Claude, Codex, Gemini, et leurs extensions dans VS Code, Cursor et Windsurf.
- **Votre langue** : 14 langues fournies, choisie d'après la langue de votre Mac. Le français est la langue d'origine ; les autres n'ont pas encore été rodées à la voix.
- **Local** : la reconnaissance vocale d'Apple tourne sur votre Mac, sans abonnement.
- **À votre façon** : toutes les phrases se règlent dans un fichier de configuration.

## Pour aller plus loin

- [Guide complet](docs/guide.md) : toutes les commandes, la configuration, les éditeurs de code.
- [Langues](docs/guide.md#adapter-à-votre-langue) : changer de langue, en corriger ou en ajouter une.
- [Dépannage](docs/guide.md#dépannage) : quand une commande ne passe pas.
- [Contribuer](docs/guide.md#contribuer) : le projet est ouvert à tous.

---

Projet indépendant, sans lien avec Anthropic, OpenAI ou Google. [Licence](LICENSE).
