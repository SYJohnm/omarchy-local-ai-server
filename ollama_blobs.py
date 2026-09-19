#!/usr/bin/env python3
"""Resolve ollama's model names to the GGUF files backing them.

ollama stores each layer as a content-addressed blob, and the model layer is a
plain GGUF -- the same format llama.cpp loads. So a model already pulled with
`ollama pull` can be served by llama-server directly, with no conversion and
no second copy on disk.

The reverse (importing a .gguf into ollama with a Modelfile) does not save
space: `ollama create` copies the file into the blob store, leaving two copies.

Usage: ollama_blobs.py <store-dir> [<store-dir> ...]
Prints {"name": {"path": ..., "size": ...}} for every resolvable model.
"""
import json
import os
import sys

# The layer holding the GGUF weights. Other layers (template, license, params,
# system) are small text blobs and are ignored.
MODEL_MEDIA_TYPES = (
    "application/vnd.ollama.image.model",
)


def model_name(manifest_path, manifests_root):
    """Rebuild "qwen3:8b" from ".../library/qwen3/8b".

    The last path segment is the tag and the rest is the repository. The
    "registry.ollama.ai/library" prefix is dropped because that is what the
    ollama CLI itself displays.
    """
    rel = os.path.relpath(manifest_path, manifests_root)
    parts = rel.split(os.sep)
    if len(parts) < 2:
        return None
    tag = parts[-1]
    repo_parts = parts[:-1]
    if repo_parts[:1] == ["registry.ollama.ai"]:
        repo_parts = repo_parts[1:]
    if repo_parts[:1] == ["library"]:
        repo_parts = repo_parts[1:]
    if not repo_parts:
        return None
    return "/".join(repo_parts) + ":" + tag


def resolve(store):
    out = {}
    manifests_root = os.path.join(store, "manifests")
    blobs_root = os.path.join(store, "blobs")
    if not os.path.isdir(manifests_root):
        return out

    for dirpath, _dirnames, filenames in os.walk(manifests_root):
        for filename in filenames:
            manifest_path = os.path.join(dirpath, filename)
            try:
                with open(manifest_path) as handle:
                    manifest = json.load(handle)
            except Exception:
                continue

            name = model_name(manifest_path, manifests_root)
            if not name:
                continue

            for layer in manifest.get("layers", []):
                if layer.get("mediaType") not in MODEL_MEDIA_TYPES:
                    continue
                digest = str(layer.get("digest", ""))
                if not digest:
                    continue
                # Blobs are stored with the digest's ":" rewritten to "-".
                blob = os.path.join(blobs_root, digest.replace(":", "-"))
                if not os.path.isfile(blob):
                    continue
                # Only offer what llama.cpp can actually open. A model pulled
                # in another format would otherwise be listed and then fail at
                # launch with an unhelpful error.
                try:
                    with open(blob, "rb") as handle:
                        if handle.read(4) != b"GGUF":
                            continue
                except OSError:
                    continue
                # The store is reported alongside each model so the caller can
                # launch a server pointed at the one that actually holds them,
                # rather than guessing and getting ollama's empty default.
                out[name] = {"path": blob, "size": layer.get("size", 0), "store": store}
                break
    return out


if __name__ == "__main__":
    result = {}
    for store in sys.argv[1:]:
        # Earlier stores win, so an explicitly configured one is not shadowed.
        for name, info in resolve(store).items():
            result.setdefault(name, info)
    print(json.dumps(result))
