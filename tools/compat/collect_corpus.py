"""Сборка корпуса плагинов из сторонних репозиториев в один каталог.

Забирает *.plugin / *.py из third_party/corpus-sources/* (склонированные
репозитории каталогов плагинов), дедуплицирует по sha256 содержимого
и раскладывает в third_party/corpus/all — формат, который ждёт scanner.

Запуск:  python -m tools.compat.collect_corpus
"""

import argparse
import hashlib
import os
import re
import shutil

from . import corpus

SKIP_DIRS = {".git", "node_modules", "__pycache__", ".github"}
SKIP_NAMES = {"conftest.py", "baseline.py", "setup.py"}
# Деревья исходников SDK не считаем плагинами.
SKIP_PATH_PARTS = ("extera_utils", "elyx_runtime")

# Плагин каталога обязан объявлять метаданные (__id__). Всё без него —
# дев-скрипты репозиториев или модули многофайловых Elyx-плагинов.
METADATA_MARKER = re.compile(r"^__id__\s*=", re.M)


def has_plugin_metadata(text):
    return METADATA_MARKER.search(text) is not None


def iter_plugin_files(roots):
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in sorted(filenames):
                if not fn.endswith(corpus.PLUGIN_EXTENSIONS):
                    continue
                if fn in SKIP_NAMES:
                    continue
                path = os.path.join(dirpath, fn)
                parts = os.path.normpath(path).split(os.sep)
                if any(p in SKIP_PATH_PARTS for p in parts):
                    continue
                yield path


def flatten_name(path, seen_names):
    base = os.path.basename(path)
    if base.endswith(".py") and base != "__init__.py":
        base = base[:-3] + ".plugin"
    name = base
    suffix = 1
    while name in seen_names:
        stem, ext = os.path.splitext(base)
        name = f"{stem}_{suffix}{ext}"
        suffix += 1
    seen_names.add(name)
    return name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sources", default=os.path.join(corpus.PROJECT_ROOT, "third_party", "corpus-sources"),
        help="корень с склонированными репо плагинов")
    parser.add_argument("--out", default=corpus.CORPUS_DIR, help="куда собрать")
    args = parser.parse_args()

    roots = [
        os.path.join(args.sources, d)
        for d in sorted(os.listdir(args.sources))
        if os.path.isdir(os.path.join(args.sources, d))
    ] if os.path.isdir(args.sources) else []

    os.makedirs(args.out, exist_ok=True)
    seen_names = set()
    seen_hashes = set()
    copied, skipped_dup, skipped_empty, skipped_nometa = 0, 0, 0, 0

    for src in iter_plugin_files(roots):
        with open(src, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        if digest in seen_hashes:
            skipped_dup += 1
            continue
        seen_hashes.add(digest)
        with open(src, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        if len(text.strip()) < 16:
            skipped_empty += 1
            continue
        if not has_plugin_metadata(text):
            skipped_nometa += 1
            continue
        name = flatten_name(src, seen_names)
        shutil.copyfile(src, os.path.join(args.out, name))
        copied += 1

    total = len([f for f in os.listdir(args.out)
                 if f.endswith(corpus.PLUGIN_EXTENSIONS)])
    print(f"copied={copied} dup={skipped_dup} empty={skipped_empty} "
          f"nometa={skipped_nometa} total_in_out={total}")
    print(f"out: {args.out}")


if __name__ == "__main__":
    main()
