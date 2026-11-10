"""Сканер корпуса плагинов: кто какие Java-классы, методы и хуки использует.

Порт логики tests/test_java_refs.py + tests/test_java_call_shape.py
из exteraless (Android), переработан из pytest-проверок в экстрактор
данных для генератора манифеста.
"""

import ast
import importlib.util
import os
import re
import warnings

from . import corpus

_FQCN_ROOTS = "|".join(corpus.JAVA_ROOTS)
FQCN_RE = re.compile(
    r"^(?:" + _FQCN_ROOTS + r")(?:\.[A-Za-z_]\w*)*\.[A-Z]\w*(?:\$[A-Za-z_]\w*)*$")
_QUOTED_FQCN = re.compile(
    r"[\"']((?:" + _FQCN_ROOTS + r")(?:\.[A-Za-z_]\w*)*\.[A-Z]\w*(?:\$[A-Za-z_]\w*)*)[\"']")
_IMPORT_FROM = re.compile(
    r"^[ \t]*from[ \t]+((?:" + _FQCN_ROOTS + r")(?:\.[A-Za-z_]\w*)*)[ \t]+import[ \t]+"
    r"(\([^)]*\)|[^\n#]+)", re.MULTILINE)
_IMPORT_PLAIN = re.compile(
    r"^[ \t]*import[ \t]+((?:" + _FQCN_ROOTS + r")(?:\.[A-Za-z_]\w*)+)", re.MULTILINE)
_IMPORTED_NAME = re.compile(r"([A-Za-z_]\w*)(?:[ \t]+as[ \t]+[A-Za-z_]\w*)?")

INIT = "<init>"
OWNED_PREFIXES = ("org.telegram.", "com.exteragram.", "app.exteraless.")
GENERATED = ("R", "BuildConfig")
FACTORY_CALLS = ("find_class", "jclass", "autoclass", "load_class", "get_class")

# High-level SDK hooks (base_plugin) — какие extension points реально нужны.
SDK_HOOK_PATTERNS = (
    re.compile(r"\badd_on_send_message_hook\b"),
    re.compile(r"\badd_on_(pre|post)_request_hook\b"),
    re.compile(r"\badd_on_app_event_hook\b"),
    re.compile(r"\badd_on_update(s)?_hook\b"),
    re.compile(r"\bon_send_message_hook\b"),
    re.compile(r"\bon_(pre|post)_request_hook\b"),
    re.compile(r"\bon_app_event_hook\b"),
    re.compile(r"\bon_update(s)?_hook\b"),
    re.compile(r"\bcreate_settings\b"),
)

# Xposed-стиль: прямой хук Java-методов.
XPOSED_FIND_HOOK = re.compile(
    r"findAndHook(?:Method|Constructor)?\s*\(\s*[\"']([\w.$]+)[\"']([^)]*)\)", re.S)
XPOSED_HOOK_CALL = re.compile(
    r"\b(?:XposedBridge|XposedHelpers)\s*\.\s*(hookMethod|findAndHookMethod|"
    r"findAndHookConstructor|deoptimizeMethod)\s*\(")
HOOK_BASE_NAMES = (
    "PyMethodHook", "PyMethodReplacement", "MethodHook", "MethodReplacement",
    "BaseHook", "XC_MethodHook")

ALIASES_PATH = os.path.join(corpus.PYTHON_ROOT, "extera_utils", "class_aliases.py")


def load_aliases():
    if not os.path.isfile(ALIASES_PATH):
        return None
    spec = importlib.util.spec_from_file_location(
        "exteraless_class_aliases_scanner", ALIASES_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _alias_resolve(alias_module):
    if alias_module is None:
        return lambda name: name
    return alias_module.resolve


# ---------------------------------------------------------------------------
# Java refs: классы, которые плагин тащит по имени (import/строки).
# ---------------------------------------------------------------------------

def plugin_java_refs(tree, source):
    """FQCN → использован (по AST и regex, как у exteraless)."""
    refs = set()

    def add(name):
        if FQCN_RE.match(name):
            refs.add(name)

    if tree is not None:
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                if node.level or not node.module:
                    continue
                if node.module.split(".")[0] not in corpus.JAVA_ROOTS:
                    continue
                for alias in node.names:
                    if alias.name != "*":
                        add(node.module + "." + alias.name)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    add(alias.name)
            elif isinstance(node, ast.Constant) and isinstance(node.value, str):
                add(node.value)
    for match in _QUOTED_FQCN.finditer(source):
        add(match.group(1))
    for match in _IMPORT_PLAIN.finditer(source):
        add(match.group(1))
    for match in _IMPORT_FROM.finditer(source):
        module, names = match.group(1), match.group(2).strip("()")
        for part in names.split(","):
            part = part.strip()
            if not part or part == "*":
                continue
            name = _IMPORTED_NAME.match(part)
            if name:
                add(module + "." + name.group(1))
    return refs


# ---------------------------------------------------------------------------
# Java calls: какие члены каких классов реально вызываются.
# ---------------------------------------------------------------------------

def _single_name(node):
    if len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
        return None
    return node.targets[0].id


def _names_in(target):
    if isinstance(target, ast.Name):
        return [target.id]
    if isinstance(target, (ast.Tuple, ast.List)):
        out = []
        for item in target.elts:
            out.extend(_names_in(item))
        return out
    if isinstance(target, ast.Starred):
        return _names_in(target.value)
    return []


def _assigned_names(node):
    if isinstance(node, ast.Assign):
        out = []
        for target in node.targets:
            out.extend(_names_in(target))
        return out
    if isinstance(node, (ast.AnnAssign, ast.AugAssign, ast.NamedExpr)):
        return _names_in(node.target)
    if isinstance(node, (ast.For, ast.AsyncFor)):
        return _names_in(node.target)
    if isinstance(node, (ast.With, ast.AsyncWith)):
        out = []
        for item in node.items:
            if item.optional_vars is not None:
                out.extend(_names_in(item.optional_vars))
        return out
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        return [node.name]
    if isinstance(node, ast.ExceptHandler):
        return [node.name] if node.name else []
    return []


def _arg_names(args):
    out = [a.arg for a in list(getattr(args, "posonlyargs", []))
           + list(args.args) + list(args.kwonlyargs)]
    if args.vararg is not None:
        out.append(args.vararg.arg)
    if args.kwarg is not None:
        out.append(args.kwarg.arg)
    return out


def _factory_target(value):
    if not isinstance(value, ast.Call) or not value.args:
        return None
    func = value.func
    name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
    if name not in FACTORY_CALLS:
        return None
    first = value.args[0]
    if not isinstance(first, ast.Constant) or not isinstance(first.value, str):
        return None
    text = first.value
    if text.split(".")[0] not in corpus.JAVA_ROOTS:
        return None
    return text


_STMT_FIELDS = ("body", "orelse", "finalbody", "handlers")
_SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)


def _flat(body):
    stack = list(body)
    while stack:
        node = stack.pop()
        yield node
        if isinstance(node, _SCOPES):
            continue
        for field in _STMT_FIELDS:
            stack.extend(getattr(node, field, None) or ())


def _argc(node):
    if node.keywords:
        return None
    for arg in node.args:
        if isinstance(arg, ast.Starred):
            return None
    return len(node.args)


class _Collector:
    """Порт _Collector из test_java_call_shape.py: трекинг вызовов."""

    def __init__(self, resolve):
        self.resolve = resolve
        self.bindings = {}
        self.records = []

    def run(self, tree):
        self._imports(tree)
        self._poison(tree)
        self._scope(tree.body, {})
        return self.records

    def _bind(self, name, fqcn):
        if name in self.bindings and self.bindings[name] != fqcn:
            self.bindings[name] = None
            return
        self.bindings[name] = fqcn

    def _imports(self, tree):
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                if node.level or not node.module:
                    continue
                if node.module.split(".")[0] not in corpus.JAVA_ROOTS:
                    continue
                for alias in node.names:
                    if alias.name != "*" and alias.name[:1].isupper():
                        self._bind(alias.asname or alias.name,
                                   node.module + "." + alias.name)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    if not alias.asname:
                        continue
                    if alias.name.split(".")[0] in corpus.JAVA_ROOTS:
                        self._bind(alias.asname, alias.name)
            elif isinstance(node, ast.Assign):
                name = _single_name(node)
                target = _factory_target(node.value)
                if name is not None and target is not None:
                    self._bind(name, target)

    def _poison(self, tree):
        for node in ast.walk(tree):
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                continue
            if isinstance(node, ast.Assign) and _factory_target(node.value):
                continue
            for name in _assigned_names(node):
                if name in self.bindings:
                    self.bindings[name] = None

    def _instance_type(self, value):
        target = _factory_target(value)
        if target is not None:
            return target
        if not isinstance(value, ast.Call):
            return None
        if not isinstance(value.func, ast.Name):
            return None
        return self.bindings.get(value.func.id)

    def _locals(self, body, local):
        seen = {}
        for node in _flat(body):
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                continue
            names = _assigned_names(node)
            if not names:
                continue
            fqcn = None
            if isinstance(node, ast.Assign) and len(names) == 1:
                fqcn = self._instance_type(node.value)
            for name in names:
                seen.setdefault(name, set()).add(fqcn if len(names) == 1 else None)
        for name, kinds in seen.items():
            if name in self.bindings:
                continue
            local[name] = kinds.pop() if len(kinds) == 1 else None

    def _scope(self, body, inherited):
        local = dict(inherited)
        self._locals(body, local)
        for stmt in body:
            self._visit(stmt, local)

    def _visit_args(self, args, local):
        for default in list(args.defaults) + [d for d in args.kw_defaults if d]:
            self._visit(default, local)

    def _visit(self, node, local):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for deco in node.decorator_list:
                self._visit(deco, local)
            self._visit_args(node.args, local)
            inner = dict(local)
            for name in _arg_names(node.args):
                inner[name] = None
            self._scope(node.body, inner)
            return
        if isinstance(node, ast.ClassDef):
            for deco in node.decorator_list:
                self._visit(deco, local)
            for base in node.bases:
                self._visit(base, local)
            for kw in node.keywords:
                self._visit(kw.value, local)
            self._scope(node.body, dict(local))
            return
        if isinstance(node, ast.Lambda):
            self._visit_args(node.args, local)
            inner = dict(local)
            for name in _arg_names(node.args):
                inner[name] = None
            self._visit(node.body, inner)
            return
        if isinstance(node, ast.Call):
            target = self._resolve(node.func, local)
            if target is None:
                self._visit(node.func, local)
            else:
                self._record(node, target[0], target[1], _argc(node))
            for arg in node.args:
                self._visit(arg, local)
            for kw in node.keywords:
                self._visit(kw.value, local)
            return
        if isinstance(node, ast.NamedExpr):
            for name in _names_in(node.target):
                local[name] = None
            self._visit(node.value, local)
            return
        if isinstance(node, ast.Attribute):
            target = self._resolve(node, local)
            if target is not None:
                self._record(node, target[0], target[1], None)
                return
            self._visit(node.value, local)
            return
        for child in ast.iter_child_nodes(node):
            self._visit(child, local)

    def _resolve(self, node, local):
        parts = []
        cur = node
        while isinstance(cur, ast.Attribute):
            parts.append(cur.attr)
            cur = cur.value
        if not isinstance(cur, ast.Name):
            return None
        parts.reverse()
        base = self.bindings.get(cur.id) or local.get(cur.id)
        if not base:
            return None
        if not parts:
            return base, INIT
        for part in parts[:-1]:
            if not part[:1].isupper():
                return None
            base = base + "$" + part
        return base, parts[-1]

    def _record(self, node, fqcn, member, argc):
        resolved = self.resolve(fqcn)
        if not resolved.startswith(OWNED_PREFIXES):
            return
        if resolved.partition("$")[0].rpartition(".")[2] in GENERATED:
            return
        self.records.append((resolved, member, argc, node.lineno))


def plugin_java_calls(tree, resolve):
    if tree is None:
        return []
    return _Collector(resolve).run(tree)


# ---------------------------------------------------------------------------
# Хуки: high-level SDK + Xposed-стиль.
# ---------------------------------------------------------------------------

def plugin_sdk_hooks(source):
    found = []
    for pattern in SDK_HOOK_PATTERNS:
        if pattern.search(source):
            found.append(pattern.pattern.replace(r"\b", "").replace("(s)?", "s"))
    return sorted(set(found))


def plugin_xposed_hooks(source, tree):
    targets = []
    for match in XPOSED_FIND_HOOK.finditer(source):
        fqcn = match.group(1)
        rest = match.group(2)
        # Последний строковый аргумент findAndHookMethod — имя метода.
        names = re.findall(r"[\"'](\w+)[\"']", rest)
        method = names[-1] if names else None
        targets.append((fqcn, method, "findAndHook"))
    uses_bridge = bool(XPOSED_HOOK_CALL.search(source))
    subclasses = set()
    if tree is not None:
        for node in ast.walk(tree):
            if isinstance(node, ast.ClassDef):
                for base in node.bases:
                    name = base.attr if isinstance(base, ast.Attribute) else getattr(base, "id", None)
                    if name in HOOK_BASE_NAMES:
                        subclasses.add(node.name)
    return targets, uses_bridge, subclasses


# ---------------------------------------------------------------------------
# Точка входа: полный отчёт по одному плагину.
# ---------------------------------------------------------------------------

def scan_plugin(plugin, resolve):
    tree = plugin.tree
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", SyntaxWarning)
        refs = plugin_java_refs(tree, plugin.source)
        calls = plugin_java_calls(tree, resolve)
        xposed, uses_bridge, subclasses = plugin_xposed_hooks(plugin.source, tree)
        sdk_hooks = plugin_sdk_hooks(plugin.source)
    # Резолвим имена классов через алиасы, как делает рантайм.
    resolved_refs = sorted({resolve(name) for name in refs})
    return {
        "name": plugin.name,
        "parsed": tree is not None,
        "refs": resolved_refs,
        "calls": [
            {"class": resolve(fqcn), "member": member, "argc": argc, "line": line}
            for fqcn, member, argc, line in calls
        ],
        "xposed": [
            {"class": resolve(fqcn), "method": method, "kind": kind}
            for fqcn, method, kind in xposed
        ],
        "xposed_bridge": uses_bridge,
        "hook_subclasses": sorted(subclasses),
        "sdk_hooks": sdk_hooks,
    }
