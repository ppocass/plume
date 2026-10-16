#!/bin/bash
# Compile whisper-server (whisper.cpp, licence MIT) en binaire autonome pour
# Apple Silicon : Metal embarqué, aucune bibliothèque hors macOS.
# Le code source est téléchargé dans .build-whisper/ (ignoré par git).
# Les chemins de compilation sont réécrits (-ffile-prefix-map) : le binaire
# ne contient pas le dossier de la personne qui compile.
# Affiche le chemin du binaire sur la dernière ligne.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="v1.9.5"
SRC="$ROOT/.build-whisper/whisper.cpp-$TAG"
BIN="$SRC/build/bin/whisper-server"
if [ ! -x "$BIN" ]; then
  command -v cmake >/dev/null || { echo "cmake est requis (brew install cmake)" >&2; exit 1; }
  mkdir -p "$ROOT/.build-whisper"
  [ -d "$SRC" ] || git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp.git "$SRC" >&2
  cmake -S "$SRC" -B "$SRC/build" -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_SDL2=OFF -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_C_FLAGS="-ffile-prefix-map=$SRC=whisper.cpp" -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$SRC=whisper.cpp" \
    -DCMAKE_OBJC_FLAGS="-ffile-prefix-map=$SRC=whisper.cpp" >&2
  cmake --build "$SRC/build" --target whisper-server -j 4 >&2
fi
echo "$BIN"
