#!/usr/bin/env python3
"""Own and lock the persistent UIKit CI source copy, including self-hosted runners.

Only a newly created directory can be claimed. Reuse requires its exact sentinel;
rsync deletion is confined to its telegram-ios child. Each command pins the stage
generation and holds the same OS lock until its child process has finished.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import errno
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time
import uuid

from client_ui_harness import command

MARKER = ".client-ui-workspace.json"
GENERATION = ".client-ui-generation.json"
LOCK = ".client-ui-workspace.lock"
KIND = "exteraless-client-ui-harness-workspace"


def checked_identity(repository, generation=None):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected the GitHub owner/repository identity")
    if generation is not None and not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", generation):
        raise ValueError("Expected a bounded run-id/attempt generation")


def regular_json(path):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 4096:
        raise ValueError("Workspace metadata must be a small regular file: " + str(path))
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("Invalid workspace metadata: " + str(path))
    return value


def verify_workspace(root, repository):
    root = Path(root).absolute()
    checked_identity(repository)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("Workspace root must be an owned real directory")
    if not (root / MARKER).exists() and not (root / MARKER).is_symlink():
        raise ValueError("Refusing an existing directory without a harness ownership sentinel: " + str(root))
    marker = regular_json(root / MARKER)
    if (marker.get("schema") != 1 or marker.get("kind") != KIND or marker.get("repository") != repository
            or marker.get("root") != str(root.resolve())):
        raise ValueError("Refusing an unowned or relocated CI workspace: " + str(root))
    uuid.UUID(marker["identity"])
    for name in ("telegram-ios", "bazel-user-root"):
        child = root / name
        if child.is_symlink() or (child.exists() and not child.is_dir()):
            raise ValueError("Owned workspace child is not a real directory: " + str(child))
    return root


def claim_workspace(root, repository):
    root = Path(root).absolute()
    checked_identity(repository)
    # No parents=True, adoption of existing empty directories, sudo/chown, or
    # recursive removal. The CI agent needs ordinary write access to the parent.
    try:
        root.mkdir(mode=0o700)
    except FileExistsError:
        return verify_workspace(root, repository)
    marker = {"schema": 1, "kind": KIND, "repository": repository,
              "root": str(root.resolve()), "identity": str(uuid.uuid4())}
    with (root / MARKER).open("x", encoding="utf-8") as stream:
        json.dump(marker, stream, sort_keys=True)
        stream.write("\n")
    return verify_workspace(root, repository)


@contextmanager
def locked_workspace(root, repository, *, create=False, wait=30):
    root = claim_workspace(root, repository) if create else verify_workspace(root, repository)
    lock_path = root / LOCK
    if lock_path.is_symlink():
        raise ValueError("Refusing a symlinked workspace lock")
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    acquired = False
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 1:
            raise ValueError("Invalid workspace lock file")
        if metadata.st_size == 0:
            os.write(descriptor, b"\0")
        deadline = time.monotonic() + wait
        while True:
            try:
                if os.name == "nt":  # Allows the ownership tests on Windows.
                    import msvcrt
                    os.lseek(descriptor, 0, os.SEEK_SET)
                    msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                    raise
                if time.monotonic() >= deadline:
                    raise TimeoutError("UIKit CI workspace is busy; no source was replaced") from error
                time.sleep(0.05)
        verify_workspace(root, repository)
        yield root
    finally:
        if acquired:
            if os.name == "nt":
                import msvcrt
                os.lseek(descriptor, 0, os.SEEK_SET)
                msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def read_generation(root, repository):
    value = regular_json(root / GENERATION)
    if (value.get("schema") != 1 or value.get("repository") != repository or type(value.get("ready")) is not bool
            or not isinstance(value.get("generation"), str)):
        raise ValueError("Unknown CI source generation metadata")
    checked_identity(repository, value.get("generation", ""))
    return value


def write_generation(root, value):
    temporary = root / (GENERATION + "." + str(uuid.uuid4()))
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
        temporary.replace(root / GENERATION)
    finally:
        temporary.unlink(missing_ok=True)


def stage(root, repository, generation, source, *, run=command, before_copy=None):
    checked_identity(repository, generation)
    source = Path(source).resolve(strict=True)
    absolute_root = Path(root).absolute()
    resolved_root = absolute_root.resolve()
    if source == resolved_root or source in resolved_root.parents or resolved_root in source.parents:
        raise ValueError("CI source checkout and owned workspace must be separate trees")
    for relative in ("versions.json", "MODULE.bazel", "Tests/ExteralessHarness/BUILD"):
        if not (source / relative).is_file():
            raise ValueError("Incomplete Telegram/harness checkout: " + relative)
    with locked_workspace(absolute_root, repository, create=True) as owned:
        if (owned / GENERATION).exists() or (owned / GENERATION).is_symlink():
            read_generation(owned, repository)
        state = {"schema": 1, "repository": repository, "generation": generation, "ready": False}
        # A failed rsync invalidates the generation; old output cannot be built as
        # a successful new stage. The sentinel/lock live OUTSIDE the deleted tree.
        write_generation(owned, state)
        if before_copy is not None:
            before_copy(source)
        destination = owned / "telegram-ios"
        destination.mkdir(exist_ok=True)
        (owned / "bazel-user-root").mkdir(exist_ok=True)
        run(["rsync", "-a", "--delete", "--delete-excluded", "--exclude=.git",
             "--exclude=/build/", "--exclude=/build-input/", "--exclude=/bazel-*", "--",
             str(source) + "/", str(destination) + "/"], timeout=300, stdout=sys.stdout)
        state["ready"] = True
        write_generation(owned, state)
        return destination


def execute_owned(root, repository, generation, argv, seconds, *, run=command):
    checked_identity(repository, generation)
    if not argv:
        raise ValueError("An owned-workspace command is required")
    with locked_workspace(root, repository) as owned:
        state = read_generation(owned, repository)
        if state["generation"] != generation or state["ready"] is not True:
            raise ValueError("CI source generation changed or staging did not finish")
        run(argv, timeout=seconds, stdout=sys.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("stage", "exec"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--generation", required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--seconds", type=int, default=600)
    options, argv = parser.parse_known_args()
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not 1 <= options.seconds <= 6720:
        parser.error("Command deadline must be 1...6720 seconds")
    def interrupted(signum, frame):
        raise SystemExit("workspace command interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    if options.action == "stage":
        if options.source is None or argv:
            parser.error("stage requires --source and accepts no child command")
        from apply_telegram_client_patches import prepare_client_sources, prove_clean_base
        def prepare_source(source):
            proof = prove_clean_base(source)
            prepare_client_sources(source)
            print(json.dumps({"clientPatchCleanBaseProof": proof}), flush=True)
        stage(options.root, options.repository, options.generation, options.source, before_copy=prepare_source)
    else:
        execute_owned(options.root, options.repository, options.generation, argv, options.seconds)


if __name__ == "__main__":
    main()
