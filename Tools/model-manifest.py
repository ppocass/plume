#!/usr/bin/env python3
"""Print the file list of a Hugging Face model, ready to paste into
Plume/Sources/Plume/ModelCatalog.swift.

    Tools/model-manifest.py FluidInference/parakeet-ultra-coreml Encoder.mlmodelc Decoder.mlmodelc ...
    Tools/model-manifest.py ggerganov/whisper.cpp ggml-large-v3.bin

The revision is pinned to the repo's current commit, so a later change on
Hugging Face can never slip past the checksums. Large (LFS) files carry their
sha256 in the API; small files are downloaded once to hash them.
"""
import hashlib
import json
import sys
import urllib.request

API = "https://huggingface.co/api/models"


def get(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    repo, wanted = sys.argv[1], sys.argv[2:]
    revision = json.loads(get(f"{API}/{repo}"))["sha"]
    tree = json.loads(get(f"{API}/{repo}/tree/{revision}?recursive=true"))
    files = []
    for f in tree:
        if f["type"] != "file":
            continue
        top = f["path"].split("/")[0]
        if top not in wanted:
            continue
        sha = (f.get("lfs") or {}).get("oid")
        if not sha:
            data = get(f"https://huggingface.co/{repo}/resolve/{revision}/{f['path']}")
            sha = hashlib.sha256(data).hexdigest()
        files.append((f["path"], f["size"], sha))
    missing = set(wanted) - {p.split("/")[0] for p, _, _ in files}
    if missing:
        sys.exit(f"not found in {repo}: {', '.join(sorted(missing))}")
    print(f'            repo: "{repo}", revision: "{revision}",')
    print("            files: [")
    for path, size, sha in sorted(files):
        print(f'                .init("{path}", {size}, "{sha}"),')
    print("            ],")


if __name__ == "__main__":
    main()
