"""Bounded Darwin-family selection witnesses, not simulated iOS acceptance.

Counted fcntl/proc and root-directory stand-ins isolate selection on Windows.
The POSIX case uses real FDs/aliases on the executing OS and is never emulated.
"""

import importlib
import os
from pathlib import Path
import posixpath
import stat
import subprocess
import sys
import tempfile
from types import ModuleType, SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
CASES = ("darwin", "ios", "linux", "root_alias_selection", "posix_fd")


def fail_resolve(*args, **kwargs):
    raise AssertionError("platform selection must not resolve a whole untrusted path")


def selectors(platform, directory):
    from exteraless_runtime import _audit_paths as audit
    target = directory / "owned.bin"
    target.write_bytes(b"owned bytes")
    fd = os.open(target, os.O_RDWR)
    calls = []
    fcntl = ModuleType("fcntl")
    fcntl.F_GETPATH = 50

    def getpath(opened, command, buffer):
        assert opened == fd and stat.S_ISREG(os.fstat(opened).st_mode)
        assert command == fcntl.F_GETPATH and buffer == bytes(1024)
        calls.append("fcntl")
        return os.fsencode(target) + b"\0" + bytes(8)

    def proc(path):
        assert path == f"/proc/self/fd/{fd}"
        calls.append("proc")
        return str(target)

    fcntl.fcntl = getpath
    try:
        assert os.read(fd, 11) == b"owned bytes"  # an actual owned fd, not fd=0
        with patch.object(audit, "sys", SimpleNamespace(platform=platform)), \
                patch.object(audit, "os", SimpleNamespace(**dict(vars(os), readlink=proc))), \
                patch.dict(sys.modules, {"fcntl": fcntl}):
            assert audit._descriptor_path(fd) == str(target)
            assert audit.ArchiveCodePaths(str(directory / "cache/writer")).fd_path(fd) == str(target)
            expected = "proc" if platform == "linux" else "fcntl"
            assert calls == [expected, expected]
            if platform in ("darwin", "ios"):
                def unavailable(*args): raise OSError("owned F_GETPATH refusal")
                fcntl.fcntl = unavailable
                assert audit._descriptor_path(fd) is None
                assert "proc" not in calls, "iOS/Darwin must not fall through to Linux /proc"
        paths = SimpleNamespace(**dict(vars(posixpath), realpath=fail_resolve))
        with patch.object(audit, "sys", SimpleNamespace(platform=platform)), \
                patch.object(audit, "os", SimpleNamespace(**dict(vars(os), path=paths, sep="/"))):
            for name in ("var", "tmp", "etc"):
                prefix = "/private" if platform in ("darwin", "ios") else ""
                assert audit._lexical("/" + name + "/owned/leaf-link") == prefix + "/" + name + "/owned/leaf-link"
            assert audit._lexical("/various/leaf") == "/various/leaf"
            assert audit._lexical("/private/var/owned") == "/private/var/owned"
    finally:
        os.close(fd)


def root_alias_selection():
    from exteraless_runtime import _archives as archives
    # Selection-only root trace. It does not implement or certify POSIX FD I/O.
    for platform in ("darwin", "ios", "linux"):
        for name in ("var", "tmp", "etc"):
            children, readlinks, roots = [], [], []

            class RootTrace:
                def __init__(self, fd, path, hook=None):
                    assert fd == 91 and path == "/"
                    self.fd, self.aliases = fd, {}
                    roots.append(self)
                def stat(self, child):
                    assert child == name
                    return SimpleNamespace(st_dev=1, st_ino=2, st_mode=stat.S_IFLNK, st_mtime_ns=3, st_ctime_ns=4)
                def child(self, child):
                    children.append(child)
                    return self
                def verify(self): pass

            def open_root(path, flags):
                assert path == "/" and flags & 1 and flags & 2 and flags & 4
                return 91

            def readlink(child, *, dir_fd):
                assert child == name and dir_fd == 91
                readlinks.append(child)
                return "private/" + child

            fake_os = SimpleNamespace(**dict(vars(os), O_DIRECTORY=1, O_CLOEXEC=2, O_NOFOLLOW=4,
                open=open_root, readlink=readlink, path=SimpleNamespace(**dict(vars(posixpath), realpath=fail_resolve))))
            with patch.object(archives, "sys", SimpleNamespace(platform=platform)), \
                    patch.object(archives, "os", fake_os), patch.object(archives, "_posix_backend", lambda: None):
                archives._Directory.open_native.__func__(RootTrace, "/" + name + "/owned")
                if platform == "linux":
                    assert children == [name, "owned"] and not readlinks and not roots[0].aliases
                else:
                    assert children == ["private", name, "owned"] and readlinks == [name]
                    assert roots[0].aliases[name][-1] == "private/" + name
                    fake_os.readlink = lambda *args, **kwargs: "/untrusted-target"
                    try: archives._Directory.open_native.__func__(RootTrace, "/" + name + "/owned")
                    except archives.ArchiveValidationError as error: assert "unexpected OS root alias" in str(error)
                    else: raise AssertionError("Darwin-family root aliases must retain their literal target check")


def posix_fd():
    from exteraless_runtime import _archives, _audit_paths
    # /tmp stays raw here; on Darwin/iOS it is a documented OS root alias.
    with tempfile.TemporaryDirectory(prefix="owned-elyx-platform-", dir="/tmp") as raw:
        root = Path(raw)
        file = root / "own.bin"
        file.write_bytes(b"owned")
        fd = os.open(file, os.O_RDWR)
        directory = _archives._Directory.open_native(raw)
        try:
            resolved = _audit_paths._descriptor_path(fd)
            assert resolved is not None and os.path.samefile(resolved, file)
            assert os.read(fd, 5) == b"owned"
            directory.verify()
            outside = root / "outside"
            outside.mkdir()
            os.symlink(outside, root / "descendant-link", target_is_directory=True)
            try: _archives._Directory.open_native(str(root / "descendant-link"))
            except _archives.ArchiveValidationError: pass
            else: raise AssertionError("Darwin-family support admitted an untrusted descendant symlink")
        finally:
            os.close(fd)
            for held in list(directory.pool): held.close()


def worker(case, directory):
    assert sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode
    sys.path.insert(0, str(ROOT / "python"))
    if case in ("darwin", "ios", "linux"): selectors(case, Path(directory))
    elif case == "root_alias_selection": root_alias_selection()
    else: posix_fd()
    print("ELYX_PLATFORM_OK " + case)


if __name__ == "__main__":
    worker(*sys.argv[1:3])
else:
    import pytest

    @pytest.mark.parametrize("case", CASES)
    def test_platform_family(case, tmp_path):
        if case == "posix_fd" and os.name != "posix":
            pytest.skip("actual POSIX FD/alias exercise; no Windows emulation")
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, str(tmp_path)],
                                cwd=tmp_path, text=True, encoding="utf-8", errors="replace", capture_output=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "ELYX_PLATFORM_OK " + case in result.stdout
