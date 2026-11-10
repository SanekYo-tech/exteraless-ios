"""Обновление baselines совместимости под текущий корпус.

Baselines exteraless записаны против их корпуса (800 плагинов); наш корпус
другой, поэтому тесты «нет новых дыр» находят записи, которых в baseline нет.
По их же регламенту (tests/README.md) закрытая дыра удаляется из списка,
новая — добавляется. Политика здесь: **объединение** — их известные дыры
сохраняются (корпус вырастет — снова пригодятся), наши добавляются.

Запуск:  python -m tools.compat.refresh_baselines
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")


def load_test_module(name):
    path = os.path.join(TESTS, name)
    spec = importlib.util.spec_from_file_location(name[:-3], path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name[:-3]] = module
    spec.loader.exec_module(module)
    return module


def refresh(name, found, baseline_name):
    from . import baseline
    known = set(baseline.load(baseline_name).get("known", ()))
    added = sorted(set(found) - known)
    if not added:
        print(f"{baseline_name}: без изменений")
        return
    payload = {"known": sorted(known | set(found))}
    baseline.save(baseline_name, payload)
    print(f"{baseline_name}: +{len(added)} записей: {added[:10]}")


def main():
    if os.name == "nt":
        os.environ.setdefault("PYTHONUTF8", "1")

    java = load_test_module("test_java_call_shape.py")
    _, buckets = java.analyse()
    refresh("java_call_members", buckets["missing_member"],
            java.MEMBER_BASELINE)
    refresh("java_call_arity", buckets["arity_mismatch"], java.ARITY_BASELINE)

    sdk = load_test_module("test_sdk_surface.py")
    report = sdk.scan_corpus()
    refresh("sdk_modules", report["missing_module"], sdk.MODULES_BASELINE)
    refresh("sdk_names", report["missing_name"], sdk.NAMES_BASELINE)

    sig = load_test_module("test_python_sdk_signatures.py")
    report = sig.scan()
    refresh("sdk_signature_positional", report["too_many_positional"],
            sig.POSITIONAL_BASELINE)
    refresh("sdk_signature_required", report["missing_required"],
            sig.REQUIRED_BASELINE)


if __name__ == "__main__":
    main()
