# VoiceWake

🇫🇷 [Français](README.fr.md) · 🇬🇧 **English**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift)
![On-device](https://img.shields.io/badge/speech-on--device-green)
![14 languages](https://img.shields.io/badge/languages-14-purple)

**Talk to Claude, Codex and Gemini hands-free. Wake word, dictation, send, answer read aloud. 100% on-device.**

Say "Hey Claude", talk, your message is sent, and the answer is read out loud. No API key, no subscription, no cloud by default: Apple's speech recognition runs on your Mac.

<!-- Demo: record ~20 s (say "Hey Claude", dictate, "OK send it", answer read aloud), save as docs/demo.gif, then uncomment:
<p align="center"><img src="docs/demo.gif" alt="VoiceWake demo" width="720"></p>
-->

## Why

AI writes the code, but you still hunt for the window, click the mic, click send, 50 times a day. VoiceWake removes every click: the frontmost window decides which assistant you're talking to (Claude Code in VS Code, the Claude app elsewhere).

- 🎙️ **Wake word**: "Hey Claude", "Hey Codex", "Hey Gemini"
- 🔁 **Continuous conversation**: the mic reopens after the answer is read
- 🧠 **Context-aware**: works in the desktop apps and in VS Code, Cursor, Windsurf
- 🔒 **Private**: speech recognition runs on your Mac; nothing is sent online unless you turn on the optional ElevenLabs voice
- 🌍 **14 languages**, picked from your Mac's language

## How it works

1. You say "**Hey Claude**": the assistant's microphone opens.
2. You talk normally.
3. You say "**OK send it**", or simply stop talking if automatic sending is on: the message goes.
4. The answer is read out loud.
5. The microphone reopens: the conversation goes on.

## Install

### Mac

You need macOS 13 or later and Apple's command line tools (`xcode-select --install`).

```bash
git clone https://github.com/RychTwins/voicewake.git
cd voicewake
./install.sh
```

Accept the three permissions (Microphone, Speech Recognition, Accessibility), open Claude and say "Hey Claude".

### Windows

You need Windows 10 or 11 and the .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`). In PowerShell:

```powershell
git clone https://github.com/RychTwins/voicewake.git
cd voicewake\windows
.\install.ps1
```

Preliminary version, French commands only, not yet tested on a real machine: see the [Windows requirements](docs/guide.en.md#windows).

## Commands to know

| You say | What happens |
| --- | --- |
| "Hey Claude", "Hey Codex", "Hey Gemini" | the assistant's microphone opens |
| "OK send it" | the message is sent |
| "OK stop" | the microphone closes, nothing is sent |
| "Stop reading", "Resume reading" | pause and resume the reading |
| "Listen" | stops the reading and reopens the microphone |
| "New chat" | new conversation |
| "Open *project name*" | opens that project |
| "Click on *button name*" | clicks that button |

There are many more: see the [full guide](docs/guide.en.md#voice-commands).

## What it does

- **Your assistants**: Claude, Codex, Gemini, and their extensions in VS Code, Cursor and Windsurf.
- **Your language**: 14 languages included, picked from your Mac's language. French is the original language; the others have not been voice-tested yet, so please report what the speech engine mishears.
- **Local**: Apple's speech recognition runs on your Mac, with no subscription.
- **Your way**: every phrase can be changed in a configuration file.

## Going further

- [Full guide](docs/guide.en.md): all commands, configuration, supported apps.
- [Languages](docs/guide.en.md#languages): switch language, fix one or add one.
- [Troubleshooting](docs/guide.en.md#troubleshooting): when a command is not understood.
- [Contributing](docs/guide.en.md#contributing): the project is open to everyone.

## Help wanted: native speakers

13 of the 14 language packs have never been voice-tested. If you speak English, Spanish, German, Portuguese, Italian, Dutch, Russian, Turkish, Arabic, Hindi, Chinese, Japanese or Korean, 10 minutes of testing helps a lot: [report what the speech engine mishears](https://github.com/RychTwins/voicewake/issues/new?template=language.yml).

If VoiceWake saves you clicks, a ⭐ helps other people find it.

---

Independent project, not affiliated with Anthropic, OpenAI or Google. [License](LICENSE).
