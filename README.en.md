# VoiceWake

🇫🇷 [Français](README.md) · 🇬🇧 **English**

**Work with Claude, Codex and Gemini by voice, without touching the keyboard.**

Say "Hey Claude", talk, your message is sent, and the answer is read out loud. Free, open source, for Mac.

## How it works

1. You say "**Hey Claude**": the assistant's microphone opens.
2. You talk normally.
3. You say "**OK send it**", or simply stop talking if automatic sending is on: the message goes.
4. The answer is read out loud.
5. The microphone reopens: the conversation goes on.

## Install

You need macOS 13 or later and Apple's command line tools (`xcode-select --install`).

```bash
git clone https://github.com/RychTwins/voicewake.git
cd voicewake
./install.sh
```

Accept the three permissions (Microphone, Speech Recognition, Accessibility), open Claude and say "Hey Claude".

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

The Windows version is preliminary and has not been tested on a real machine.

---

Independent project, not affiliated with Anthropic, OpenAI or Google. [License](LICENSE).
