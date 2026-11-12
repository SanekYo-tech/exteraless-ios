import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

# Тесты C-моста импортируют python.bridge, который тянет бинарное
# расширение _exteraless_bridge. Если расширение не собрано под ТЕКУЩИЙ
# интерпретатор (например, локально .pyd от 3.14, а гоняем 3.12) —
# честно исключаем эти файлы из collection, а не роняем сьют.
_BRIDGE_DIR = os.path.join(REPO_ROOT, "python", "bridge")


def _bridge_extension_available():
    if not os.path.isdir(_BRIDGE_DIR):
        return False
    major, minor = sys.version_info.major, sys.version_info.minor
    # Windows: _exteraless_bridge.cp312-win_amd64.pyd
    # Linux/macOS: _exteraless_bridge.cpython-312-x86_64-linux-gnu.so
    tags = (f"cp{major}{minor}", f"cpython-{major}{minor}")
    for name in os.listdir(_BRIDGE_DIR):
        if not name.startswith("_exteraless_bridge"):
            continue
        if not name.endswith((".pyd", ".so")):
            continue
        if any(tag in name for tag in tags):
            return True
        # нетипизированное имя без тега тоже грузится
        if name in ("_exteraless_bridge.pyd", "_exteraless_bridge.so"):
            return True
    return False


if not _bridge_extension_available():
    collect_ignore = ["test_bridge.py", "test_bridge_isolation.py"]
