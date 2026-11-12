"""Восстановление exec-битов в git-индексе после коммита с Windows.

Windows-ФС не хранит execute-бит, поэтому vendored-дерево попало в git
с режимом 100644: скрипты (build-ffmpeg-bazel.sh и др.) на macOS-CI
падают с permission denied. Находит по shebang (#!) и расширению
(.sh/.command) все такие файлы и ставит им mode 100755 в индексе.

Поиск shebang — git grep (C, быстро); обновление — один вызов
update-index --index-info (без чанков).

Использование: python tools/fix_exec_bits.py [--dry-run]
"""

import argparse
import subprocess
import sys

EXEC_EXTENSIONS = (".sh", ".command")
TARGET_PREFIX = "telegram-ios/"


def git(*args, input_data=None):
    return subprocess.run(
        ["git", *args],
        input=input_data,
        capture_output=True,
        text=True,
        check=True,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    # 1. Быстро находим все файлы со shebang силами Git (C, многопоточно).
    shebang_paths = set(
        git("grep", "-l", "-I", "^#!", "--", TARGET_PREFIX).stdout.splitlines()
    )

    # 2. Получаем только файлы внутри TARGET_PREFIX со статусом 100644.
    listing = git("ls-files", "-s", "--", TARGET_PREFIX).stdout.splitlines()
    candidates = []
    for line in listing:
        meta, _, path = line.partition("\t")
        parts = meta.split()
        if len(parts) < 3 or parts[0] != "100644":
            continue
        sha = parts[1]
        if path.lower().endswith(EXEC_EXTENSIONS) or path in shebang_paths:
            candidates.append((sha, path))

    print(f"кандидатов на +x: {len(candidates)}")
    if args.dry_run:
        for _, path in candidates[:40]:
            print(" ", path)
        return 0
    if not candidates:
        return 0

    # 3. Обновляем индекс чанками: --index-info на Windows с
    #    core.fileMode=false режим не применяет, а --chmod=+x работает.
    chunk = 80
    for start in range(0, len(candidates), chunk):
        batch = [path for _, path in candidates[start:start + chunk]]
        git("update-index", "--chmod=+x", "--", *batch)
        print(f"  обработано {min(start + chunk, len(candidates))}"
              f"/{len(candidates)}")
    print("готово: git commit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
