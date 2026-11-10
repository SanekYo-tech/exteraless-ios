"""Порт tests/corpus.py из exteraless (Android) для генератора манифеста.

Корни путей настраиваются переменными окружения:
  EXTERALESS_ANDROID_ROOT  — корень исходников exteraless (Android-форк)
  EXTERALESS_PLUGIN_CORPUS — каталог корпуса плагинов (*.plugin / *.py)
"""

import ast
import functools
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(HERE))

REPO = os.environ.get(
    "EXTERALESS_ANDROID_ROOT",
    os.path.join(PROJECT_ROOT, "third_party", "exteraless-android"),
)

PYTHON_ROOT = os.path.join(REPO, "TMessagesProj", "src", "main", "python")
JAVA_ROOT = os.path.join(REPO, "TMessagesProj", "src", "main", "java")
MAPPING_DIR = os.path.join(REPO, "TMessagesProj", "build", "outputs", "mapping", "release")
CORPUS_DIR = os.environ.get(
    "EXTERALESS_PLUGIN_CORPUS",
    os.path.join(PROJECT_ROOT, "third_party", "corpus", "all"))
ARCHIVES_DIR = os.environ.get(
    "EXTERALESS_PLUGIN_ARCHIVES",
    os.path.join(PROJECT_ROOT, "third_party", "corpus", "archives"))

JAVA_ROOTS = ("java", "javax", "android", "androidx", "org", "com", "kotlin", "dalvik")

PLUGIN_EXTENSIONS = (".plugin", ".py")

SOURCE_ROOTS = (JAVA_ROOT,)
# TMessagesProj_Modules (media/media3) в корпус порта не входят.
MODULE_ROOTS = ()


def find_java_source(fqcn):
    rel = os.path.join(*fqcn.split(".")) + ".java"
    for root in SOURCE_ROOTS:
        path = os.path.join(root, rel)
        if os.path.isfile(path):
            return path
    return None


class Plugin:

    def __init__(self, path, source):
        self.path = path
        self.name = os.path.basename(path)
        self.source = source

    @property
    def tree(self):
        try:
            return ast.parse(self.source, filename=self.name)
        except SyntaxError:
            return None

    def __repr__(self):
        return f"<Plugin {self.name}>"


@functools.lru_cache(maxsize=1)
def load_corpus():
    if not os.path.isdir(CORPUS_DIR):
        return ()
    out = []
    for fn in sorted(os.listdir(CORPUS_DIR)):
        path = os.path.join(CORPUS_DIR, fn)
        if not os.path.isfile(path):
            continue
        if not fn.endswith(PLUGIN_EXTENSIONS):
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            out.append(Plugin(path, fh.read()))
    return tuple(out)


@functools.lru_cache(maxsize=1)
def java_source_classes():
    found = set()
    for dirpath, _, files in os.walk(JAVA_ROOT):
        rel = os.path.relpath(dirpath, JAVA_ROOT).replace(os.sep, ".")
        for fn in files:
            if fn.endswith(".java"):
                found.add(f"{rel}.{fn[:-5]}" if rel != "." else fn[:-5])
    return frozenset(found)


@functools.lru_cache(maxsize=1)
def java_nested_classes():
    pattern = re.compile(
        r"^\s*(?:public|protected|private)?\s*(?:static\s+)?(?:final\s+|abstract\s+)*"
        r"(?:class|interface|enum|@interface)\s+(\w+)")
    found = {}
    for dirpath, _, files in os.walk(JAVA_ROOT):
        rel = os.path.relpath(dirpath, JAVA_ROOT).replace(os.sep, ".")
        for fn in files:
            if not fn.endswith(".java"):
                continue
            outer = f"{rel}.{fn[:-5]}" if rel != "." else fn[:-5]
            names = set()
            with open(os.path.join(dirpath, fn), encoding="utf-8",
                      errors="replace") as fh:
                for line in fh:
                    m = pattern.match(line)
                    if m:
                        names.add(m.group(1))
            names.discard(fn[:-5])
            found[outer] = frozenset(names)
    return found


@functools.lru_cache(maxsize=1)
def r8_mapping():
    # R8-маппинг есть только после Android-сборки; для манифеста не нужен.
    return frozenset(), {}


@functools.lru_cache(maxsize=1)
def r8_removed():
    return frozenset()
