"""Инициализация сабмодулей Telegram-iOS по точным пинам.

Релизный снапшот не содержал сабмодулей (пустые каталоги). Скрипт для
каждого пути из docs/submodule-pins.json:
  1) делает пустой git-репо в каталоге сабмодуля,
  2) fetch --depth 1 <sha> с origin (GitHub умеет fetch по SHA),
  3) checkout FETCH_HEAD и удаляет FETCH_HEAD/рекламу,
  4) прописывает запись в .gitmodules (path/url),
  5) git add каталога -> родительский репо фиксирует gitlink (mode 160000).

Итог: содержимое не раздувает наш репозиторий, а CI забирает сабмодули
через actions/checkout с submodules: recursive.

Запуск:  python tools/fetch_submodules.py [--only path1 path2]
Память: последовательно, без параллельных клонов; крупные репо (webrtc)
качаются один раз.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PINS_PATH = os.path.join(REPO_ROOT, "docs", "submodule-pins.json")


def run(args, cwd=None, check=True):
    print("  $", " ".join(args))
    return subprocess.run(args, cwd=cwd, check=check,
                          capture_output=True, text=True)


def submodule_ready(path):
    """Уже инициализирован и на нужном коммите?"""
    head_file = os.path.join(path, ".git", "HEAD")
    return os.path.isfile(head_file)


def init_one(rel_path, url, sha, force=False):
    abs_path = os.path.join(REPO_ROOT, rel_path)
    os.makedirs(abs_path, exist_ok=True)

    if submodule_ready(abs_path) and not force:
        result = run(["git", "rev-parse", "HEAD"], cwd=abs_path, check=False)
        if result.returncode == 0 and result.stdout.strip() == sha:
            print(f"  уже на {sha[:10]}, пропуск")
            return True

    # чистим каталог (мог остаться пустым или мусорным)
    if force:
        for entry in os.listdir(abs_path):
            if entry == ".git":
                continue
            full = os.path.join(abs_path, entry)
            if os.path.isdir(full):
                shutil.rmtree(full)
            else:
                os.remove(full)
    if not os.path.isdir(os.path.join(abs_path, ".git")):
        run(["git", "init", "-q"], cwd=abs_path)
        run(["git", "remote", "add", "origin", url], cwd=abs_path)

    # fetch точного коммита (shallow) и checkout
    run(["git", "fetch", "--depth", "1", "origin", sha], cwd=abs_path)
    run(["git", "checkout", "-q", "FETCH_HEAD"], cwd=abs_path)

    # .gitmodules в родителе
    name = rel_path.replace("/", "_")
    run(["git", "config", "-f", ".gitmodules",
         f"submodule.{name}.path", rel_path], cwd=REPO_ROOT)
    run(["git", "config", "-f", ".gitmodules",
         f"submodule.{name}.url", url], cwd=REPO_ROOT)
    return True


def git_add_gitlinks(paths):
    """Зафиксировать gitlink-и в индексе родителя."""
    run(["git", "add", *paths], cwd=REPO_ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", nargs="*", default=None,
                        help="ограничить пути (vault-relative)")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    with open(PINS_PATH, encoding="utf-8") as fh:
        pins = json.load(fh)["submodules"]

    items = list(pins.items())
    if args.only:
        wanted = set(args.only)
        items = [(p, d) for p, d in items if p in wanted]

    done = []
    for rel_path, data in items:
        print(f"\n=== {rel_path} @ {data['sha'][:10]}")
        try:
            init_one(rel_path, data["url"], data["sha"], force=args.force)
            done.append(rel_path)
        except subprocess.CalledProcessError as exc:
            print(f"  FAILED rc={exc.returncode}: {exc.stderr[-400:]}",
                  file=sys.stderr)
            return 1

    if done:
        git_add_gitlinks(done)
    print(f"\nготово: {len(done)}/{len(items)} сабмодулей")
    print("дальше: git add .gitmodules docs/submodule-pins.json tools/fetch_submodules.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
