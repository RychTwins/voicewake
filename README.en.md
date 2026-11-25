# VoiceWake

🇫🇷 [Français](README.md) · 🇬🇧 **English**

**Work with Claude, Codex and Gemini by voice, without touching the keyboard.**

Say "Hey Claude": VoiceWake opens the app, turns on its built-in microphone, you dictate your request, and "OK send it" sends it. The answer is then read out loud. It also works inside VS Code and the editors built on it.

- **Local and free**: Apple's speech recognition running on your Mac, no API, no subscription.
- **Invisible**: a background service with no window and no icon, started when you log in.
- **Context-aware**: the frontmost window decides. In VS Code, "Hey Claude" targets the Claude Code extension; elsewhere, the Claude app.
- **Hands-free from start to finish**: wake, dictate, send, listen to the answer, interrupt it.
- **In your language**: 14 languages included, picked automatically from your Mac's language.

> **Open source and free.** Download it, try it on your Mac, improve it and adapt it to the way you work. Contributions are welcome.

> **About this English version.** VoiceWake was written and tested in French. The English commands below come from the English language pack: they pass the project's tests, but they have not been voice-tested by native speakers yet. If a command is not recognised, see [When a command is not understood](#when-a-command-is-not-understood) and please report it. Log messages and the output of the terminal commands are still in French.

> Independent project, not affiliated with Anthropic, OpenAI or Google.

---

## How it works, in five steps

1. You say "**Hey Claude**" (or "Hey Codex", "Hey Gemini"…): the assistant's microphone opens.
2. You talk normally.
3. You say "**OK send it**", or you simply stop talking if automatic sending is on: the message goes.
4. When the answer is ready, it is read out loud.
5. With continuous conversation on, the microphone reopens after the reading: you keep talking without touching anything.

Everything else (navigating, clicking a button, running a skill, answering a question) is done by voice too.

---

## Quick start

**Requirements**: macOS 13 or later, Apple's command line tools (`xcode-select --install`).

```bash
git clone https://github.com/RychTwins/voicewake.git
cd voicewake
./install.sh
```

1. Accept the three permissions macOS asks for: **Microphone**, **Speech Recognition** and **Accessibility** (VoiceWake clicks the apps' buttons for you).
2. Check the installation: `voicewake check`.
3. Open Claude and say "**Hey Claude**", then your request, then "**OK send it**".

`install.sh` compiles the program, signs it with a local certificate created once (so macOS keeps the permissions from one version to the next), installs `~/Applications/VoiceWake.app`, writes the configuration **in your Mac's language**, and starts the service. The `voicewake` command is installed in `~/.local/bin`.

---

## Voice commands

Say each command **on its own**, with a short pause before it and about a second of silence after it.

### Call an assistant

| Say | Effect |
| --- | --- |
| "Hey Claude", "Hi Claude", "Hello Claude" | Claude's microphone |
| "Hey Codex" | Codex's microphone |
| "Hey Gemini" | Gemini's microphone |
| "Hey assistant" | the assistant of the frontmost app, otherwise the default one |
| "Claude." (the name alone, then silence) | same effect; never in the middle of a sentence |

The app is launched if it is closed, then brought to the front.

### While dictating

| Say | Effect |
| --- | --- |
| "OK send it", "OK send", "Send the message", "Go ahead, send" | closes the microphone and sends |
| "OK stop", "Stop listening", "Cancel that", "Never mind" | closes the microphone without sending; say "OK send it" within 3 minutes to send anyway |
| "Wait, I'm thinking" | with `continuousConversation` on: pauses automatic sending until you speak again |
| "Hey Gemini" (another assistant) | stops this dictation without sending and opens the other one |

**Sending when you stop talking.** Set `"continuousConversation": true` and VoiceWake sends your message after a few seconds of silence (`autoSendSilenceSeconds`, 5 by default; `0` turns it off). As long as words are being recognised, VoiceWake considers you are still talking. With `"naturalTurnEnd": false` the delay is always the same; otherwise a sentence that ends on a hanging word ("and", "because") waits longer.

Keep the app in front until the message is sent: if another app stays in front for more than 2 seconds, sending is cancelled.

### While the answer is read aloud

| Say | Effect |
| --- | --- |
| "Stop reading", "Pause reading" | pause |
| "Resume reading", "Continue reading" | resume |
| "Listen", "Listen to me" | pause and reopen the microphone for a new request |
| "Read the answer", "Read it aloud" | reads the last answer again |
| "Read from …" followed by a few words of the passage | reads from that point |
| "Faster", "Slower", "Repeat", "Next sentence" | only after "Read from …" |

### Manage the assistant

| Say | Effect |
| --- | --- |
| "New chat", "New conversation", "New session" | starts a new conversation |
| "Clear the draft" | empties the input field |
| "Copy the answer" | copies the last answer |
| "Where are we?" | says what VoiceWake is doing right now |
| "What commands?" | says what you can do in the frontmost app |

### Navigate and click

| Say | Effect |
| --- | --- |
| "Open *project name*" | opens that project in the sidebar |
| "New session in *project name*" | new session in that project |
| "Next session", "Previous session", "Next page", "Go back" | navigation |
| "Code mode", "Chat mode" | switches tab in Claude |
| "Open settings", "Show the terminal", "Hide the sidebar", "Zoom in" | the matching menu |
| "Menu *item name*" | any item of the menu bar |
| "Click on *button name*" | any visible button |
| "Run the skill *name*" | types the slash command, then waits for "OK send it" |
| "Palette *command*" | opens the command palette and types the command |
| "Write *text*" | types the text in the focused field |
| "Enter key", "Escape key", "Down arrow" | a key |

**Sensitive actions** (delete, quit, send, pay, sign out…) are never run directly: VoiceWake asks "Confirm …?" and only acts if you say "**I confirm**" within 8 seconds. "No", "Cancel" or silence do nothing.

### Answer a question from the assistant

When Claude shows a question with options: "The first", "Option two", the option's label, "My answer is …" for a free answer, or "Skip".

---

## Languages

VoiceWake listens to **one language at a time**, the one set in `locale`: Apple's speech engine cannot follow two at once.

| Language | `locale` | Status |
| --- | --- | --- |
| French | `fr-FR` | original language, used and voice-tested |
| English | `en-US` | pack included |
| Spanish | `es-ES` | pack included |
| Portuguese | `pt-BR` | pack included |
| German | `de-DE` | pack included |
| Italian | `it-IT` | pack included |
| Dutch | `nl-NL` | pack included |
| Russian | `ru-RU` | pack included |
| Turkish | `tr-TR` | pack included |
| Arabic | `ar-SA` | pack included |
| Hindi | `hi-IN` | pack included |
| Chinese (Simplified Mandarin) | `zh-CN` | pack included |
| Japanese | `ja-JP` | pack included |
| Korean | `ko-KR` | pack included |

The included packs are complete translations, checked by the project's tests, but **not yet voice-tested** by people who speak those languages.

**The language is chosen for you.** At install time, `./install.sh` reads your Mac's language and writes the configuration in that language, with its regional variant when the speech engine knows it (`en-GB`, `es-MX`, `pt-PT`…). A Mac in a language with no pack gets English.

Outside French, `requireOnDevice` is `false`: if macOS has no local speech model for your language, VoiceWake still starts by using Apple's online recognition (your voice is then sent to Apple). As soon as a local model exists, it is used instead. Set it back to `true` to forbid any upload.

To switch language later (`auto` = your Mac's language), back up your configuration first, then:

```bash
voicewake exemple es --config config.example.json > ~/.config/voicewake/config.json
```

**Japanese, Korean, Turkish, Hindi**: in these languages the verb normally comes last, but commands followed by a name (open a project, click a button, pick a menu) must start with the keyword. The pack therefore gives a keyword-first form.

### When a command is not understood

Speech engines often mishear names and short words ("Claude" heard as "clawed"). To fix it:

1. Set `"debug": true` in `~/.config/voicewake/config.json` and restart the service.
2. Say the command and look at what was written in `~/Library/Logs/voicewake.log`.
3. Add that spelling to the `phrases` of the assistant in your configuration, or to your language pack.
4. Check with `voicewake route "hey claude"`.

### Add or improve a language

```bash
voicewake langue es
```

This lists everything a pack must provide (about 200 items) and what is still missing. It also rejects an unsafe pack, for example one where a sensitive action could be confirmed with a single word. Two ways to write a pack:

- without recompiling: `~/.config/voicewake/lang/es.json`, with the keys `phrases`, `lists`, `maps`, `speech`;
- in the project: `src/Lang+xx.swift`, modelled on `src/Lang+en.swift`, plus one line in `Lang.builtIn`.

Each French phrase is a key; its value is the list of what people say in your language.

---

## Supported apps

| App | How |
| --- | --- |
| Claude (desktop) | built-in microphone, send, read aloud, navigation |
| Codex (ChatGPT desktop) | built-in dictation, send, read aloud |
| Gemini (desktop) | built-in microphone, send, read aloud |
| Antigravity | VoiceWake listens itself and types the text |
| VS Code, Cursor, Windsurf, VSCodium | Claude Code and Codex extensions, when their panel is open |

Button labels depend on each app's interface language. VoiceWake already knows the French and English labels; add yours with `|` in the configuration (`button:Envoyer|Send`).

---

## Configuration

Everything is in `~/.config/voicewake/config.json`. After a change, restart the service:

```bash
launchctl kickstart -k gui/$(id -u)/io.github.voicewake
```

| Key | Meaning |
| --- | --- |
| `locale` | the language VoiceWake listens to |
| `targets[].phrases` | what you say to call each assistant |
| `sendPhrases`, `stopPhrases` | what you say to send, or to stop without sending |
| `continuousConversation` | send on silence, and reopen the microphone after the answer is read |
| `autoSendSilenceSeconds` | seconds of silence before sending |
| `defaultTarget` | the assistant used by "Hey assistant" when none is in front |
| `elevenLabs` | optional: an ElevenLabs voice instead of the Mac's voice for VoiceWake's own announcements |
| `debug` | writes what was heard in the log |

**ElevenLabs voice (optional).** By default VoiceWake calls no online service and speaks with a Mac voice. With an ElevenLabs account, put your key in `~/.config/voicewake/elevenlabs.env` (one line `ELEVENLABS_API_KEY=…`), set `"elevenLabs": { "enabled": true, "voiceID": "…" }`, and choose a voice that is native in your language. The text to say is then sent to ElevenLabs.

---

## Terminal commands

The command names and their output are in French for now.

```bash
voicewake check                    # configuration, apps found, permissions
voicewake diagnostic               # permissions, apps, speech models
voicewake route "hey claude"       # what a sentence would trigger
voicewake test claude              # triggers Claude in 3 seconds, without the voice
voicewake langue en                # language pack: what is translated, what is missing
voicewake exemple auto --config config.example.json   # starting configuration in a language
voicewake bilan                    # the commands that failed most often
tail -f ~/Library/Logs/voicewake.log
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Nothing happens when you speak | the sentence was transcribed differently | turn on `debug`, then add that spelling to `phrases` |
| The message is sent while you are still talking | microphone input volume too low | System Settings > Sound > Input: raise the volume (about 75%) |
| Sending is cancelled | another window or chat stayed in front for more than 2 seconds | keep the starting chat on screen; the log says which |
| "OK send it" does nothing | the phrase is not in `sendPhrases` | add your own phrase to `sendPhrases` |
| A button is not found | panel closed, or interface in another language | open the panel; add your label with `\|` |
| VoiceWake asks for a permission at startup | Accessibility refused | System Settings > Privacy & Security > Accessibility |
| VoiceWake seems deaf | speech engine stuck | nothing to do: it restarts itself; otherwise restart the service |

Do not let two coding agents modify and reinstall VoiceWake at the same time: each one overwrites the other's version.

---

## Known limits

- The orange microphone indicator stays on while VoiceWake listens: this is a macOS protection.
- Outside French, free-form sentence interpretation is off, and the optional Mac commands (Finder, music, browser, Settings) are not translated yet.
- **Windows**: a preliminary, much simpler version is in [`windows/`](windows). It has never been tested on a real Windows machine.
- The full reference (every option, every command) is in the [French README](README.md).

---

## Uninstall

```bash
./uninstall.sh
```

---

## Contributing

The project is open to everyone: new languages, new assistants, other editors, fixes.

1. Fork the repository and create a branch.
2. Check your changes: `./install.sh`, `voicewake check`, then `bash tests/route.sh ~/.local/bin/voicewake`, `bash tests/route-en.sh ~/.local/bin/voicewake` and `bash tests/langues.sh ~/.local/bin/voicewake`.
3. Open a pull request describing what you tested (app, language, macOS version).

Found a bug, or a command your language's speech engine mishears? Open an [issue](https://github.com/RychTwins/voicewake/issues) with the useful part of `~/Library/Logs/voicewake.log` (in `debug` mode it contains what you said: read it before sharing).

---

## License

See [LICENSE](LICENSE).
