"""Разовая правка портированных тестов: импорты + кодировки.

Читает тесты из исходного репозитория exteraless (UTF-8), правит импорты
на пакет tools.compat и записывает в tools/compat/tests/.
"""

import os
import re

SRC = r"C:\Users\sasha\Downloads\exteraless-13.1.1-beta15\exteraless-13.1.1-beta15\tests"
HERE = os.path.dirname(os.path.abspath(__file__))
DST = os.path.join(HERE, "compat", "tests")

TESTS = [
    "test_plugin_parse.py",
    "test_capability_scan.py",
    "test_class_alias_bridge.py",
]

IMPORT_FIXES = [
    (re.compile(r"(?m)^import baseline$"), "from tools.compat import baseline"),
    (re.compile(r"(?m)^import corpus$"), "from tools.compat import corpus"),
    (re.compile(r"(?m)^import javaapi$"), "from tools.compat import javaapi"),
    (re.compile(
        r"sys\.path\.insert\(0, os\.path\.dirname\(os\.path\.abspath\(__file__\)\)\)"),
     "sys.path.insert(0, os.path.dirname(os.path.dirname("
     "os.path.dirname(os.path.abspath(__file__)))))"),
]

# media3-сабмодули в vendored-копии отсутствуют — честный skip
# перед финальным assert.
ALIAS_SKIP_INSERT = (
    "        missing.append(target)\n"
    "    assert not missing, (\n",
    "        missing.append(target)\n"
    "    if not corpus.MODULE_ROOTS and missing and all(\n"
    "            target.startswith(\"androidx.media\") for target in missing):\n"
    "        pytest.skip(\n"
    "            \"media3-сабмодули не в vendored-копии: \" + \", \".join(missing))\n"
    "    assert not missing, (\n",
)


def main():
    os.makedirs(DST, exist_ok=True)
    for name in TESTS:
        with open(os.path.join(SRC, name), encoding="utf-8") as fh:
            text = fh.read()
        for pattern, repl in IMPORT_FIXES:
            text = pattern.sub(repl, text)
        if name == "test_class_alias_bridge.py":
            old, new = ALIAS_SKIP_INSERT
            assert old in text, f"{name}: маркер для skip-вставки не найден"
            text = text.replace(old, new, 1)
        with open(os.path.join(DST, name), "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"ported {name}")


if __name__ == "__main__":
    main()
