<p align="center"><img src="docs/icon.png" width="128" alt="Plume icon"></p>

# Plume

Plume is voice dictation for the Mac. Press a key, talk, press it again, and the text appears wherever your cursor is.

Speech recognition runs on your Mac, so your voice doesn't leave it. It works in any app you type in: mail, notes, chat, your browser, the terminal.

[Download Plume](https://github.com/ppocass/plume/releases/latest/download/Plume.dmg) | [Website](https://plume-vert.vercel.app) | [Version française](README.fr.md)

## Install

1. Open `Plume.dmg` and drag Plume into Applications.
2. Open Plume. macOS will say it can't check the developer. That's expected: Plume isn't signed with a paid Apple developer account. Go to System Settings > Privacy & Security, scroll down and click **Open Anyway**.
3. Allow the **Microphone** (to hear you) and **Accessibility** (for the shortcut and to type the text). The setup assistant walks you through both, it takes a minute.

On first launch Plume downloads its speech model (about 630 MB for the default one). After that you don't need a connection.

## How to use it

- Press your shortcut key once to start, once to stop (**fn** by default). The text is typed where the cursor is.
- Press it twice quickly to cancel.
- No text field under the cursor? The text is kept in History and a click copies it.

Prefer another key? Pick any shortcut in Settings. With fn, set System Settings > Keyboard > "Press 🌐 key to" to "Do Nothing" so macOS doesn't open the emoji picker at the same time.

## Models

The setup assistant picks the model that suits your Mac. You can change it later in the Models page.

- **Parakeet Ultra** (default): 25 European languages, runs on the Neural Engine, very fast even with 8 GB of memory.
- **Whisper Turbo, Turbo compact and Large v3**: 99 languages and they use your vocabulary list. Better on Macs with 16 GB or more.
- **Online**: send the audio to Groq, OpenAI or any OpenAI-compatible service, with your own API key.

Every model comes from Hugging Face at a fixed revision and is checked against its SHA-256 before use.

## Text cleanup (optional)

Plume can fix punctuation and remove filler words ("um", "uh") with a language model. You'll need your own API key for this. A free key from [Groq](https://console.groq.com/keys) is enough. Paste it in Settings > Cleanup. Only the text is sent, never your voice, and only if cleanup is on. Without a key, you get the raw transcription, which is already pretty good.

## Privacy

- Your voice is processed on your Mac (unless you choose the Online model).
- The microphone is only open while you dictate.
- History (last 200 dictations) and your vocabulary stay in `~/Library/Application Support/Plume`.
- API keys are stored in the macOS keychain.
- No analytics, no account, nothing to sign up for.

## Requirements

- A Mac with Apple Silicon (M1 or later)
- macOS 14 Sonoma or later

## Build it yourself

You need the Xcode command line tools and `cmake` (`brew install cmake`).

```sh
git clone https://github.com/ppocass/plume.git
cd plume
./make-dmg.sh        # builds Plume, parakeet-server and whisper-server, then dist/Plume.dmg
./make-app.sh        # or: build and install straight into ~/Applications
```

## License

Plume is MIT licensed. It bundles [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) and [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT). The Parakeet models are by NVIDIA and moondream, under CC BY 4.0. Details in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
