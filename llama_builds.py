#!/usr/bin/env python3
"""Finds every llama-server build on this machine and says what each one is.

    llama_builds.py [EXTRA_PATH ...]

People keep more than one build: the distribution package, a checkout of
upstream llama.cpp, and forks carrying features upstream does not have yet
(extra KV cache types, new speculative decoding). The widget lets a model pick
the build it runs on, so each build is identified here rather than guessed
from its path:

  fork      the checkout's git remote ("ggml-org/llama.cpp",
            "spiritbuun/llama-cpp-turboquant-cuda"); "system package" for a
            binary under /usr with no checkout
  version   build number and commit from --version, commit date from git
  gpu       CUDA / ROCm / Vulkan / SYCL / Metal / CPU, from the ggml backend
            libraries shipped next to the binary
  cacheTypes  the KV cache types its --help allows -- the capability that
            differs most between forks, and the one a launch fails on

EXTRA_PATH entries (the configured binaries) come first, then the usual
install locations, then any checkout under $HOME with a build/bin/. The same
file reached through a symlink is listed once.

Prints a JSON array. Always exits 0: a build that cannot be run is skipped.
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")

FIXED = [
    HOME + "/llama.cpp/build/bin/llama-server",
    HOME + "/.local/bin/llama-server",
    "/usr/bin/llama-server",
    "/usr/local/bin/llama-server",
    "/opt/llama.cpp/bin/llama-server",
]

# Checkouts built in place. One and two levels under $HOME cover ~/llama.cpp,
# ~/forks/ik_llama.cpp, ~/src/whatever; build/bin/Release is the MSVC-style
# layout some CMake presets produce even on Linux.
GLOBS = [
    HOME + "/*/build/bin/llama-server",
    HOME + "/*/*/build/bin/llama-server",
    HOME + "/*/build/bin/Release/llama-server",
    HOME + "/*/build-*/bin/llama-server",
    "/opt/*/bin/llama-server",
    "/opt/*/build/bin/llama-server",
]

GPU_LIBS = [("cuda", "CUDA"), ("hip", "ROCm"), ("vulkan", "Vulkan"),
            ("sycl", "SYCL"), ("metal", "Metal"), ("opencl", "OpenCL")]


def candidates(extra):
    seen, out = set(), []

    def add(p):
        if not p:
            return
        p = os.path.expanduser(p)
        if not (os.path.isfile(p) and os.access(p, os.X_OK)):
            return
        real = os.path.realpath(p)
        if real in seen:
            return
        seen.add(real)
        out.append(p)

    for p in extra:
        add(p)
    for p in FIXED:
        add(p)
    add(shutil.which("llama-server"))
    for pattern in GLOBS:
        for p in sorted(glob.glob(pattern)):
            add(p)
    return out


def run(argv, timeout=15):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return r.stdout + r.stderr
    except (OSError, subprocess.SubprocessError):
        return None


def git_root(path):
    d = os.path.dirname(os.path.realpath(path))
    for _ in range(5):
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return ""


def git(root, *args):
    out = run(["git", "-C", root] + list(args), timeout=5)
    return out.strip() if out else ""


def repo_name(url):
    # https://github.com/owner/name(.git) or git@github.com:owner/name.git
    m = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$", url or "")
    return "%s/%s" % (m.group(1), m.group(2)) if m else ""


def gpu_backend(path):
    dirs = [os.path.dirname(os.path.realpath(path))]
    if dirs[0].startswith("/usr/"):
        dirs += ["/usr/lib", "/usr/lib64", "/usr/local/lib"]
    names = []
    for d in dirs:
        try:
            names += [n.lower() for n in os.listdir(d) if n.startswith("libggml")]
        except OSError:
            pass
    found = [label for key, label in GPU_LIBS if any("ggml-" + key in n for n in names)]
    return " + ".join(found) if found else "CPU"


def cache_types(help_text):
    # "-ctk,  --cache-type-k TYPE   KV cache data type for K
    #                               allowed values: f32, f16, ..., q5_1,
    #                               turbo2, turbo3, ...
    #                               (default: f16)"
    lines = help_text.splitlines()
    for i, line in enumerate(lines):
        if re.search(r"--cache-type-k\s+TYPE", line) and "draft" not in line:
            block = " ".join(l.strip() for l in lines[i + 1:i + 8])
            m = re.search(r"allowed values:\s*(.*?)(?:\(|$)", block)
            if not m:
                return []
            return [v for v in (t.strip() for t in m.group(1).split(",")) if re.match(r"^[a-z0-9_]+$", v)]
    return []


def describe(path):
    version_out = run([path, "--version"])
    if version_out is None:
        return None
    m = re.search(r"version:\s*(\S+)\s*\(build\s+(\d+),\s*commit\s+([0-9a-f]+)\)", version_out)
    root = git_root(path)
    remote = repo_name(git(root, "remote", "get-url", "origin")) if root else ""
    if remote.lower() in ("ggml-org/llama.cpp", "ggerganov/llama.cpp"):
        fork = "llama.cpp"
    elif remote:
        fork = remote.split("/")[1]
    elif path.startswith("/usr/"):
        fork = "llama.cpp (system package)"
    else:
        # A build without its checkout: name it after the directory it was
        # built in, which is usually the project's.
        parts = os.path.realpath(path).split(os.sep)
        fork = parts[parts.index("build") - 1] if "build" in parts[1:] else "llama-server"
    help_out = run([path, "--help"]) or ""
    return {
        "path": path,
        "real": os.path.realpath(path),
        "fork": fork,
        "repo": remote,
        "version": m.group(1) if m else "",
        "build": m.group(2) if m else "",
        "commit": (m.group(3) if m else git(root, "rev-parse", "--short", "HEAD") if root else "")[:9],
        "date": git(root, "log", "-1", "--format=%cs") if root else "",
        "gpu": gpu_backend(path),
        "cacheTypes": cache_types(help_out),
    }


def main():
    builds = []
    for p in candidates(sys.argv[1:]):
        info = describe(p)
        if info:
            builds.append(info)
    print(json.dumps(builds))


if __name__ == "__main__":
    main()
