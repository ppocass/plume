# Third-party notices

Plume's own code is under the MIT license (see `LICENSE`). It ships with or
downloads the following work by others.

## Bundled in the app

**FluidAudio** (inside `parakeet-server`)
Copyright FluidInference. Apache License 2.0.
https://github.com/FluidInference/FluidAudio

**whisper.cpp / ggml** (`whisper-server`)
Copyright (c) 2023-2026 The ggml authors. MIT License.
https://github.com/ggml-org/whisper.cpp

## Downloaded on first use (not included in the app)

**Parakeet Ultra** (default model): `moondream/parakeet-ultra`, a post-trained
version of NVIDIA `parakeet-tdt-0.6b-v3`, converted to Core ML by
FluidInference (`FluidInference/parakeet-ultra-coreml`).
License: Creative Commons Attribution 4.0 (CC BY 4.0),
https://creativecommons.org/licenses/by/4.0/

**Whisper large-v3 and large-v3-turbo** (optional): OpenAI Whisper weights,
MIT License, in the ggml format published by the whisper.cpp project
(`ggerganov/whisper.cpp` on Hugging Face).

Each model is fetched from Hugging Face at a fixed revision and checked
against its SHA-256 checksum before use.
