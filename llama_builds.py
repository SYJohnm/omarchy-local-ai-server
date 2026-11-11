#!/usr/bin/env python3
"""Finds every llama-server build on this machine and says what each one is.

    llama_builds.py [EXTRA_PATH ...] [--trust APPROVED_PATH ...]

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
install locations, then any build/bin/ under $HOME, release archives under
~/Downloads and ~/Applications, and /opt. The same file reached through a
symlink is listed once.

Identifying a build means running it: --version prints the build number and
commit, --help lists the KV cache types, and nothing on disk carries either.
So the execution is confined rather than avoided -- see sandbox() -- and that
is what makes it safe to identify a binary the user has not vouched for.

Being identified is not permission to be launched. A build that does not
clear the gate is listed with its reason and kept out of Auto and out of a
launch until the panel passes its path after --trust. See substitution_risk()
and provenance_doubt(). Without bwrap there is no safe way to identify an
unvouched build, so those are listed unidentified instead.

Prints a JSON array. Always exits 0: a build that cannot be run is skipped.
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HOME = os.path.expanduser("~")

# Identification runs the binary, so it runs it in here. Absent on a machine
# without bubblewrap, which costs detail rather than safety: an unvouched
# build is then listed unidentified instead of being run.
BWRAP = shutil.which("bwrap")

# Fork releases sometimes rename the server binary. Both names speak the same
# CLI; describe() still runs --version/--help before accepting one.
SERVER_NAMES = ("llama-server", "beellama-server")

FIXED = [
    HOME + "/llama.cpp/build/bin/llama-server",
    HOME + "/.local/bin/llama-server",
    HOME + "/.local/bin/beellama-server",
    "/usr/bin/llama-server",
    "/usr/local/bin/llama-server",
    "/opt/llama.cpp/bin/llama-server",
]

# Checkouts built in place, plus extracted release archives. One and two levels
# under $HOME cover ~/llama.cpp, ~/forks/ik_llama.cpp, ~/src/whatever;
# build/bin/Release is the MSVC-style layout some CMake presets produce even on
# Linux. Downloads/*/* is the usual shape of a release tarball
# (llama-b1234-bin-.../llama-b1234/llama-server). Being listed here only means
# the file is looked at; provenance_doubt() decides whether it may be run.
GLOBS = []
for _name in SERVER_NAMES:
    GLOBS += [
        HOME + "/*/build/bin/" + _name,
        HOME + "/*/*/build/bin/" + _name,
        HOME + "/*/build/bin/Release/" + _name,
        HOME + "/*/build-*/bin/" + _name,
        HOME + "/Downloads/*/" + _name,
        HOME + "/Downloads/*/*/" + _name,
        HOME + "/Applications/*/" + _name,
        "/opt/*/bin/" + _name,
        "/opt/*/build/bin/" + _name,
    ]

# Somewhere a build only arrives by being installed: a package manager wrote
# it, or the user did so by hand. Nothing downloaded lands here by accident,
# so these need no approval. Kept as realpaths with a trailing separator so a
# sibling like /usrlocal cannot prefix-match.
INSTALL_DIRS = tuple(os.path.realpath(d) + os.sep
                     for d in ("/usr", "/opt", HOME + "/.local/bin"))

GPU_LIBS = [("cuda", "CUDA"), ("hip", "ROCm"), ("vulkan", "Vulkan"),
            ("sycl", "SYCL"), ("metal", "Metal"), ("opencl", "OpenCL")]


# Two kinds of doubt, kept apart because only one of them is the user's to
# answer.

def substitution_risk(path):
    """Ways another account on this machine could change what runs.

    Never waivable. The user cannot consent on another account's behalf, and a
    build they approved yesterday could be a different program today.
    """
    try:
        st = os.stat(path)
    except OSError:
        return ["cannot be read"]
    out = []
    if st.st_uid not in (os.getuid(), 0):
        out.append("is owned by another user")
    if st.st_mode & 0o022:
        out.append("can be rewritten by other users on this machine")
    try:
        d = os.stat(os.path.dirname(os.path.realpath(path)))
        # Without the sticky bit, write on the directory is enough to unlink
        # the binary and put another one in its place.
        if (d.st_mode & 0o022) and not (d.st_mode & 0o1000):
            out.append("is in a directory other users can write to")
    except OSError:
        pass
    return out


def provenance_doubt(path):
    """Why nothing shows the user meant to run this build.

    This is the question the panel asks, and nothing on disk can answer it for
    them. Every signal that looks like proof is one an archive supplies about
    itself: extracting it makes the user the owner of every file in it, mode
    0755 and all; it picks its own directory name; and it can ship a .git
    directory, so a checkout above the binary vouches for nothing either. An
    install location is the one exception -- a package manager wrote it, or
    the user put it there by hand -- so everything else is held.
    """
    real = os.path.realpath(path)
    for d in INSTALL_DIRS:
        if real.startswith(d):
            return []
    if real.startswith(os.path.realpath(HOME + "/Downloads") + os.sep):
        return ["is in ~/Downloads, so its presence only shows that something "
                "was downloaded, not that you chose to run it"]
    return ["was found by scanning, so nothing shows where it came from"]


def candidates(extra, approved):
    """(paths to run, held entries). Every candidate goes through one gate.

    A configured path is where to look, not permission to run: it is checked
    like the rest, so a typo pointing into a world-writable directory cannot
    launder a binary past the gate either.
    """
    seen, run, held = set(), [], []
    ok = set(os.path.realpath(os.path.expanduser(p)) for p in approved)

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
        why = substitution_risk(p)
        if why:
            # Approval cannot reach this: see substitution_risk.
            held.append({"path": p, "real": real, "why": why, "blocked": True})
            return
        why = [] if real in ok else provenance_doubt(p)
        if why:
            held.append({"path": p, "real": real, "why": why, "blocked": False})
        else:
            run.append(p)

    # Configured first, so Auto prefers the build the user named.
    for p in extra:
        add(p)
    for p in FIXED:
        add(p)
    add(shutil.which("llama-server"))
    for pattern in GLOBS:
        for p in sorted(glob.glob(pattern)):
            add(p)
    return run, held


def sandbox(argv, allow_dir):
    """argv confined so that identifying a build cannot double as running it.

    No network, nothing writable, no $HOME, no environment, no capabilities,
    its own PID namespace, and uid 65534 inside. The binary's own directory is
    bound read-only because its sibling .so files are what it links against;
    /opt comes along for CUDA and ROCm runtimes, which live there.

    Returns None when bwrap is absent, which callers read as "cannot identify
    this safely" rather than falling back to running it unconfined.
    """
    if not BWRAP:
        return None
    return [BWRAP,
            "--unshare-all", "--die-with-parent", "--new-session",
            "--cap-drop", "ALL", "--uid", "65534", "--gid", "65534",
            # The environment of a desktop session carries tokens and API keys.
            "--clearenv", "--setenv", "PATH", "/usr/bin",
            "--setenv", "HOME", "/nonexistent",
            # /tmp is mounted before the build's directory is bound: a tmpfs
            # mounted over a parent afterwards would hide the binary, which
            # looks exactly like "not a llama-server".
            "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
            "--ro-bind", "/usr", "/usr",
            "--ro-bind-try", "/etc", "/etc",
            "--ro-bind-try", "/opt", "/opt",
            "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib", "/lib64",
            "--symlink", "usr/bin", "/bin", "--symlink", "usr/bin", "/sbin",
            "--ro-bind", allow_dir, allow_dir,
            "--chdir", "/", "--"] + argv


def run(argv, timeout=5, confine=None):
    # confine=<dir> runs argv in the sandbox with that directory readable.
    # Reading a repository with git is confined for the same reason the binary
    # is: a .git/config carries core.pager, core.fsmonitor and aliases, so a
    # checkout shipped inside an archive is as executable as the binary is.
    if confine is not None:
        argv = sandbox(argv, confine)
        if argv is None:
            return None
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
    out = run(["git", "-C", root] + list(args), timeout=5, confine=root)
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


def flags(help_text):
    # The flag column is everything before the two-or-more spaces that start
    # the description. Extract every flag token from it, so both "-t" and
    # "--threads" are known. Description lines are skipped.
    out = set()
    for line in help_text.splitlines():
        # Split like Params.parseLlamaHelp: the flag column can contain its own
        # two-space gaps ("-h,    --help, --usage"), so walk the chunks while
        # they still start with a dash and stop at the description.
        for chunk in re.split(r"\s{2,}", line.strip()):
            if not chunk.startswith("-"):
                break
            out.update(re.findall(r"--?[A-Za-z0-9][\w-]*", chunk))
    return sorted(out)


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


def dir_fork(path):
    # A build with no checkout: name it after the directory it was built or
    # extracted in, which is usually the project's.
    parts = os.path.realpath(path).split(os.sep)
    if "build" in parts[1:]:
        return parts[parts.index("build") - 1]
    return parts[-2] if len(parts) >= 2 else "llama-server"


def describe(path, confine=True):
    # confine=False is for a build that cleared the gate on a machine with no
    # bwrap: an install location, where a package manager put the binary.
    box = os.path.dirname(os.path.realpath(path)) if confine else None
    version_out = run([path, "--version"], confine=box)
    if version_out is None:
        return None
    m = re.search(r"version:\s*(\S+)\s*\(build\s+(\d+),\s*commit\s+([0-9a-f]+)\)", version_out)
    help_out = run([path, "--help"], confine=box) or ""
    flag_list = flags(help_out)
    # A wrong-architecture binary can be run through a binfmt handler that
    # prints its own error and still exits 0. It has no llama.cpp version and
    # no llama.cpp flags; do not offer it as a build.
    if not m and not flag_list:
        return None
    root = git_root(path)
    remote = repo_name(git(root, "remote", "get-url", "origin")) if root else ""
    if remote.lower() in ("ggml-org/llama.cpp", "ggerganov/llama.cpp"):
        fork = "llama.cpp"
    elif remote:
        fork = remote.split("/")[1]
    elif path.startswith("/usr/"):
        fork = "llama.cpp (system package)"
    else:
        fork = dir_fork(path)
        if "beellama" in fork.lower():
            fork = "beellama"
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
        "flags": flag_list,
    }


def parse_argv(args):
    # EXTRA_PATH... says where else to look; the paths after --trust say which
    # builds may be run. Separate lists on purpose: naming a path and trusting
    # what is at it are different statements.
    extra, approved, bucket = [], [], None
    for a in args:
        if a == "--trust":
            bucket = approved
        elif a:
            (extra if bucket is None else bucket).append(a)
    return extra, approved


def main():
    raw_extra, approved = parse_argv(sys.argv[1:])
    extras = [os.path.expanduser(p) for p in raw_extra]
    paths, held = candidates(extras, approved)

    # Identification is confined, so a build that has not been vouched for is
    # identified too -- the user needs to see which fork and version it is to
    # decide about it at all, and that is exactly what cannot be read off the
    # disk. Clearing the gate buys a launch, not a look.
    jobs = [(p, False) for p in paths]
    if BWRAP:
        jobs = [(p, True) for p in paths] + [(h["path"], True) for h in held]

    # A build that hangs on --version (broken driver, slow mount) must not hold
    # the others: describe them together and keep candidate order.
    with ThreadPoolExecutor(max_workers=4) as pool:
        described = list(pool.map(lambda j: describe(j[0], j[1]), jobs))

    gate = {}
    for h in held:
        gate[h["real"]] = h
    builds = []
    for info in described:
        if not info:
            continue
        h = gate.get(info["real"])
        if h:
            # Identified, and still not launchable: `missing` is already what
            # keeps a build out of Auto and out of a launch (Backends.js
            # isUsableBuild / pickBuild), so the bar does not need a new rule.
            info["missing"] = True
            info["needsApproval"] = not h["blocked"]
            info["blocked"] = h["blocked"]
            info["why"] = h["why"]
        builds.append(info)

    # A configured path that is missing, or exists but is not a runnable
    # llama-server (wrong architecture, broken download), must be visible:
    # silently dropping it is why a stale "Add fork" path looked like the
    # plugin simply refused to detect the fork.
    seen = {b["real"] for b in builds}

    # A build that did not clear the gate is listed rather than hidden: the
    # panel offers it with its reason and runs it only once trusted. Silently
    # omitting it is what made ~/Downloads builds look undetectable, and it is
    # also what hid the fact that one had been executed to identify it.
    for h in held:
        if h["real"] in seen:
            continue
        seen.add(h["real"])
        # No bwrap, or the sandbox could not run it: listed unidentified
        # rather than run unconfined to find out.
        builds.append({
            "path": h["path"],
            "real": h["real"],
            "fork": dir_fork(h["path"]),
            "repo": "",
            "version": "",
            "build": "",
            "commit": "",
            "date": "",
            "gpu": "",
            "cacheTypes": [],
            "flags": [],
            # Rides `missing`, which is already how a build is kept out of Auto
            # and out of a launch (Backends.isUsableBuild / pickBuild).
            "missing": True,
            "needsApproval": not h["blocked"],
            "blocked": h["blocked"],
            "why": h["why"],
        })

    for path in extras:
        real = os.path.realpath(path)
        if real in seen:
            continue
        seen.add(real)
        exists = os.path.isfile(path) and os.access(path, os.X_OK)
        builds.append({
            "path": path,
            "real": real,
            "fork": "missing" if not exists else "unsupported",
            "repo": "",
            "version": "",
            "build": "",
            "commit": "",
            "date": "",
            "gpu": "",
            "cacheTypes": [],
            "flags": [],
            "missing": True,
        })
    print(json.dumps(builds))


if __name__ == "__main__":
    main()
