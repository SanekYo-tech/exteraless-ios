/* _exteraless_bridge.c — C-мост virtual-java для iOS-порта exteraless (этап 2).
 *
 * Назначение: BridgeBackend — реализация протокола python.virtualjava.backend.Backend,
 * маршрутизирующая вызовы прокси в нативные (Swift/C) сервисы через реестр
 * колбэков. На iOS реестр наполняет Swift (один раз при старте), на Windows —
 * встроенный C-mock (xt_install_mock_service) и/или ctypes-колбэки из тестов.
 *
 * ============================ МАРШАЛЛИНГ ============================
 *   Python -> сервис (json_args / json_value, UTF-8 JSON):
 *     None/bool/int/float/str  — нативные JSON-значения (по значению);
 *     list/tuple/dict          — рекурсивно в JSON (kwargs всегда dict);
 *     JavaInstance и прочие объекты — маркер {"__handle__": <int64 id>,
 *                                "__fqcn": <str|null>}; объект кладётся в
 *                                handle-таблицу (id генерируется мостом, > 0);
 *     int за пределами int64   — ошибка (задокументированное ограничение).
 *   Сервис -> Python (json_result, UTF-8 JSON):
 *     любое JSON-значение; контейнеры проходятся рекурсивно;
 *     {"__handle__": id}              — объект из handle-таблицы:
 *                                        тот же id => ТОТ ЖЕ объект (identity);
 *     {"__handle__": id, "__fqcn": F} — неизвестный id => JavaInstance(F,
 *                                        backend) регистрируется под id
 *                                        (хост создаёт объекты; Swift должен
 *                                        использовать id < 0, чтобы не
 *                                        пересекаться с мостом);
 *     {"__error__": "msg"}            — JavaMemberError(msg) (на любом уровне);
 *     прочее                          — как есть (str/int/float/bool/None/...).
 *
 * ====================== РЕЕСТР СЕРВИСОВ (Swift-сторона) ======================
 *   Реестр глобален на процесс (см. TODO о суб-интерпретаторах ниже).
 *   Имя сервиса = "<prefix>.<op>", где op из:
 *     construct | call | call_instance | get | get_instance | set | set_instance
 *   BridgeBackend(service="java") ищет "java.call" и т.д. Регистрация:
 *     xt_register_service(name, callback_ptr)   — ptr = int-адрес C-функции
 *     xt_unregister_service(name) -> bool
 *     xt_service_ptr(name) -> int
 *
 *   СИГНАТУРЫ КОЛБЭКОВ (все вызываются С УДЕРЖАННЫМ GIL — см. ниже):
 *
 *     int (*construct_fn)(const char* fqcn,
 *                         const char* json_args,      -- {"args":[...],"kwargs":{}}
 *                         char** json_result);        -- malloc()! мост освободит free()
 *
 *     int (*call_fn)(const char* fqcn, const char* member,
 *                    const char* json_args, char** json_result);
 *
 *     int (*call_instance_fn)(int64_t handle, const char* fqcn,
 *                             const char* member,
 *                             const char* json_args, char** json_result);
 *
 *     int (*get_fn)(const char* fqcn, const char* member, char** json_result);
 *
 *     int (*get_instance_fn)(int64_t handle, const char* fqcn,
 *                            const char* member, char** json_result);
 *
 *     int (*set_fn)(const char* fqcn, const char* member,
 *                   const char* json_value);          -- самодостаточное JSON-значение
 *
 *     int (*set_instance_fn)(int64_t handle, const char* fqcn,
 *                            const char* member, const char* json_value);
 *
 *   Контракт памяти: при rc == 0 колбэк кладёт в *json_result malloc()-указатель
 *   на NUL-terminated UTF-8 JSON (или NULL — «нет значения» => None); мост
 *   копирует и освобождает его через free(). При rc != 0 результат
 *   игнорируется (если был выделен — колбэк обязан освободить сам) и мост
 *   поднимает JavaMemberError. Внутри результата допустим {"__error__": ...} —
 *   тогда JavaMemberError с текстом от хоста. Пустая строка результата => None.
 *
 *   Адрес для xt_register_service Swift получает как @convention(c)-указатель
 *   (Int(bitPattern:)), Python-тесты — ctypes.cast(cb, ctypes.c_void_p).value
 *   или xt_builtin_ptr(op).
 *
 * ============================== GIL ===========================================
 *   Все колбэки вызываются из методов BridgeBackend (Python C-API) С
 *   УДЕРЖАННЫМ GIL: колбэки могут свободно использовать CPython C-API (так
 *   поступает встроенный mock). Мост НЕ отпускает GIL на время колбэка; если
 *   колбэку нужно длинное нативное вычисление, он сам отпускает GIL
 *   (PyGILState_Release / Py_BEGIN_ALLOW_THREADS) и обязан вернуть его перед
 *   возвратом управления. Контракт ошибок: вернуться без pending-исключения
 *   (rc == 0 и чистый error indicator, либо rc != 0; мусорное исключение мост
 *   считает сбоем вызова). Реестр и handle-таблица мутируются только под GIL;
 *   Swift должен регистрировать сервисы до появления потоков, зовущих мост.
 *
 * ======================= СУБ-ИНТЕРПРЕТАТОРЫ (TODO) ===========================
 *   Сейчас m_size = 0 (модульное состояние пустое): реестр сервисов,
 *   handle-таблица, mock-лог и связанные классы — статические глобалы на
 *   процесс. TODO для
 *   Py_mod_multiple_interpreters:
 *     1) вынести состояние в struct xt_state + PyModule_GetState();
 *     2) m_size = sizeof(struct xt_state);
 *     3) добавить слот {Py_mod_multiple_interpreters,
 *                       Py_MOD_PER_INTERPRETER_GIL_SUPPORTED};
 *     4) реестр Swift-колбэков оставить общим на процесс (указатели не зависят
 *        от интерпретатора), handle-таблицы — по интерпретатору.
 *   Слот честно не включён: состояние ещё глобальное.
 *
 * Зависимости: CPython 3.12+; stdlib-модуль json (сериализация);
 * классы virtualjava.proxy.JavaInstance / virtualjava.backend.JavaMemberError
 * передаются в xt_bind из python/bridge/__init__.py (мост не знает путей
 * импорта хоста). Компилировать с /utf-8 (MSVC) — исходник в UTF-8.
 */

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================ операции/типы колбэков ==================== */

enum {
    OP_CONSTRUCT = 0,
    OP_CALL,
    OP_CALL_INSTANCE,
    OP_GET,
    OP_GET_INSTANCE,
    OP_SET,
    OP_SET_INSTANCE,
    OP_COUNT
};

static const char *const OP_SUFFIX[OP_COUNT] = {
    "construct", "call", "call_instance", "get", "get_instance",
    "set", "set_instance"
};

typedef int (*xt_construct_fn)(const char *fqcn, const char *json_args,
                               char **json_result);
typedef int (*xt_call_fn)(const char *fqcn, const char *member,
                          const char *json_args, char **json_result);
typedef int (*xt_call_instance_fn)(int64_t handle, const char *fqcn,
                                   const char *member, const char *json_args,
                                   char **json_result);
typedef int (*xt_get_fn)(const char *fqcn, const char *member,
                         char **json_result);
typedef int (*xt_get_instance_fn)(int64_t handle, const char *fqcn,
                                  const char *member, char **json_result);
typedef int (*xt_set_fn)(const char *fqcn, const char *member,
                         const char *json_value);
typedef int (*xt_set_instance_fn)(int64_t handle, const char *fqcn,
                                  const char *member, const char *json_value);

/* ============================ глобальное состояние ======================
 * TODO (суб-интерпретаторы): перенести в module state, см. шапку файла. */

#define XT_MAX_SERVICES 64
#define XT_SERVICE_NAME_MAX 160

typedef struct {
    char name[XT_SERVICE_NAME_MAX];
    void *fn;
} ServiceEntry;

static ServiceEntry g_services[XT_MAX_SERVICES];
static int g_n_services = 0;

/* handle-таблица: int64 id -> PyObject* (owned). Открытая адресация. */
typedef struct {
    int64_t id;
    PyObject *obj;   /* NULL = пусто */
} HandleSlot;

/* обратный индекс: (void*)obj -> id (объект удерживается g_handles). */
typedef struct {
    PyObject *obj;   /* NULL = пусто */
    int64_t id;
} RevSlot;

static HandleSlot *g_handles = NULL;
static size_t g_handle_cap = 0;   /* степень двойки */
static size_t g_handle_used = 0;
static RevSlot *g_rev = NULL;
static size_t g_rev_cap = 0;
static size_t g_rev_used = 0;
static int64_t g_next_handle = 1; /* мост раздаёт положительные id */

/* Классы из virtualjava (биндятся xt_bind из python.bridge.__init__). */
static PyObject *g_JavaInstance = NULL;
static PyObject *g_JavaMemberError = NULL;

/* json.dumps / json.loads (кэш импорта на модуль). */
static PyObject *g_json_dumps = NULL;
static PyObject *g_json_loads = NULL;
static PyObject *g_dumps_kw = NULL;   /* {"ensure_ascii": False} */

/* встроенный mock-сервис: лог вызовов + счётчик хостовых handle (< 0). */
static PyObject *g_mock_log = NULL;
static int64_t g_mock_next_handle = -1;
#define XT_MOCK_LOG_CAP 4096

/* путь к манифесту по умолчанию (repo/build/compat/manifest.json). */
static char *g_default_manifest = NULL;

/* =========================================================================
 * вспомогательные функции
 * ========================================================================= */

static char *dup_cstr(const char *s, Py_ssize_t n)
{
    char *copy = (char *)malloc((size_t)n + 1);
    if (copy == NULL)
        return NULL;
    memcpy(copy, s, (size_t)n);
    copy[n] = '\0';
    return copy;
}

static void *registry_find(const char *name)
{
    for (int i = 0; i < g_n_services; i++) {
        if (strcmp(g_services[i].name, name) == 0)
            return g_services[i].fn;
    }
    return NULL;
}

static int registry_upsert(const char *name, void *fn)
{
    for (int i = 0; i < g_n_services; i++) {
        if (strcmp(g_services[i].name, name) == 0) {
            g_services[i].fn = fn;
            return 0;
        }
    }
    if (g_n_services >= XT_MAX_SERVICES) {
        PyErr_SetString(PyExc_RuntimeError,
                        "xt_register_service: registry is full "
                        "(XT_MAX_SERVICES)");
        return -1;
    }
    if (strlen(name) >= XT_SERVICE_NAME_MAX) {
        PyErr_Format(PyExc_ValueError,
                     "xt_register_service: name too long: %.40s...", name);
        return -1;
    }
    strcpy(g_services[g_n_services].name, name);
    g_services[g_n_services].fn = fn;
    g_n_services++;
    return 0;
}

static int registry_remove(const char *name)
{
    for (int i = 0; i < g_n_services; i++) {
        if (strcmp(g_services[i].name, name) == 0) {
            g_services[i] = g_services[g_n_services - 1];
            g_n_services--;
            return 1;
        }
    }
    return 0;
}

/* --- поднятие JavaMemberError ------------------------------------------- */

/* Всегда возвращает -1 (для return bridge_error(...) < 0). Формат — как у
 * PyUnicode_FromFormat (%s, %d, %R, %S, ...). */
static int bridge_error(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    PyObject *msg = PyUnicode_FromFormatV(fmt, ap);
    va_end(ap);
    if (msg == NULL)
        return -1;
    PyObject *type = g_JavaMemberError != NULL ? g_JavaMemberError
                                               : PyExc_RuntimeError;
    PyObject *exc = PyObject_CallOneArg(type, msg);
    Py_DECREF(msg);
    if (exc == NULL)
        return -1;
    PyErr_SetObject(type, exc);
    Py_DECREF(exc);
    return -1;
}

/* --- handle-таблица (все операции под GIL) ------------------------------ */

static size_t ht_hash_i64(int64_t id)
{
    uint64_t x = (uint64_t)id;
    x = x * 0x9E3779B97F4A7C15ULL;   /* Fibonacci hashing */
    return (size_t)(x >> 32);
}

static size_t ht_hash_ptr(void *p)
{
    return (size_t)((((uintptr_t)p >> 4) * 0x9E3779B97F4A7C15ULL) >> 24);
}

static int ht_grow(void)
{
    size_t newcap = g_handle_cap ? g_handle_cap * 2 : 256;
    HandleSlot *nh = (HandleSlot *)calloc(newcap, sizeof(HandleSlot));
    RevSlot *nr = (RevSlot *)calloc(newcap, sizeof(RevSlot));
    if (nh == NULL || nr == NULL) {
        free(nh);
        free(nr);
        PyErr_NoMemory();
        return -1;
    }
    for (size_t i = 0; i < g_handle_cap; i++) {
        if (g_handles[i].obj == NULL)
            continue;
        size_t j = ht_hash_i64(g_handles[i].id) & (newcap - 1);
        while (nh[j].obj != NULL)
            j = (j + 1) & (newcap - 1);
        nh[j] = g_handles[i];
    }
    for (size_t i = 0; i < g_rev_cap; i++) {
        if (g_rev[i].obj == NULL)
            continue;
        size_t j = ht_hash_ptr(g_rev[i].obj) & (newcap - 1);
        while (nr[j].obj != NULL)
            j = (j + 1) & (newcap - 1);
        nr[j] = g_rev[i];
    }
    free(g_handles);
    free(g_rev);
    g_handles = nh;
    g_rev = nr;
    g_handle_cap = newcap;
    g_rev_cap = newcap;
    return 0;
}

static PyObject *ht_resolve(int64_t id)   /* borrowed, или NULL */
{
    if (g_handle_cap == 0)
        return NULL;
    size_t j = ht_hash_i64(id) & (g_handle_cap - 1);
    for (size_t probes = 0; probes < g_handle_cap; probes++) {
        if (g_handles[j].obj == NULL)
            return NULL;
        if (g_handles[j].id == id)
            return g_handles[j].obj;
        j = (j + 1) & (g_handle_cap - 1);
    }
    return NULL;
}

static int64_t ht_reverse_lookup(PyObject *obj)
{
    if (g_rev_cap == 0)
        return 0;
    size_t j = ht_hash_ptr((void *)obj) & (g_rev_cap - 1);
    for (size_t probes = 0; probes < g_rev_cap; probes++) {
        if (g_rev[j].obj == NULL)
            return 0;
        if (g_rev[j].obj == obj)
            return g_rev[j].id;
        j = (j + 1) & (g_rev_cap - 1);
    }
    return 0;
}

/* Регистрирует obj под НОВЫМ id (или возвращает существующий id). */
static int64_t ht_insert(PyObject *obj)
{
    int64_t existing = ht_reverse_lookup(obj);
    if (existing != 0)
        return existing;

    if (g_handle_cap == 0 || g_handle_used * 4 >= g_handle_cap * 3) {
        if (ht_grow() < 0)
            return 0;
    }
    int64_t id = g_next_handle++;
    size_t j = ht_hash_i64(id) & (g_handle_cap - 1);
    while (g_handles[j].obj != NULL)
        j = (j + 1) & (g_handle_cap - 1);
    g_handles[j].id = id;
    g_handles[j].obj = Py_NewRef(obj);
    g_handle_used++;

    size_t r = ht_hash_ptr((void *)obj) & (g_rev_cap - 1);
    while (g_rev[r].obj != NULL)
        r = (r + 1) & (g_rev_cap - 1);
    g_rev[r].obj = obj;   /* без INCREF: объект уже удерживается g_handles */
    g_rev[r].id = id;
    g_rev_used++;
    return id;
}

/* Регистрирует obj под id, выбранным хостом (construct/unmarshal). */
static int ht_insert_with_id(PyObject *obj, int64_t id)
{
    if (id == 0 || ht_resolve(id) != NULL) {
        PyErr_Format(PyExc_ValueError, "handle %lld already used",
                     (long long)id);
        return -1;
    }
    if (g_handle_cap == 0 || g_handle_used * 4 >= g_handle_cap * 3) {
        if (ht_grow() < 0)
            return -1;
    }
    size_t j = ht_hash_i64(id) & (g_handle_cap - 1);
    while (g_handles[j].obj != NULL)
        j = (j + 1) & (g_handle_cap - 1);
    g_handles[j].id = id;
    g_handles[j].obj = Py_NewRef(obj);
    g_handle_used++;

    if (ht_reverse_lookup(obj) == 0) {
        size_t r = ht_hash_ptr((void *)obj) & (g_rev_cap - 1);
        while (g_rev[r].obj != NULL)
            r = (r + 1) & (g_rev_cap - 1);
        g_rev[r].obj = obj;
        g_rev[r].id = id;
        g_rev_used++;
    }
    return 0;
}

static int ht_remove(int64_t id)
{
    if (g_handle_cap == 0)
        return 0;
    size_t j = ht_hash_i64(id) & (g_handle_cap - 1);
    int found = 0;
    for (size_t probes = 0; probes < g_handle_cap; probes++) {
        if (g_handles[j].obj == NULL)
            return 0;
        if (g_handles[j].id == id) {
            found = 1;
            break;
        }
        j = (j + 1) & (g_handle_cap - 1);
    }
    if (!found)
        return 0;
    PyObject *obj = g_handles[j].obj;
    if (g_rev_cap) {
        size_t r = ht_hash_ptr((void *)obj) & (g_rev_cap - 1);
        for (size_t probes = 0; probes < g_rev_cap; probes++) {
            if (g_rev[r].obj == NULL)
                break;
            if (g_rev[r].obj == obj && g_rev[r].id == id) {
                g_rev[r].obj = NULL;
                g_rev_used--;
                break;
            }
            r = (r + 1) & (g_rev_cap - 1);
        }
    }
    Py_DECREF(obj);
    g_handles[j].obj = NULL;
    g_handle_used--;
    /* переустановка кластера после удаления (линейное пробирование) */
    size_t k = (j + 1) & (g_handle_cap - 1);
    while (g_handles[k].obj != NULL) {
        int64_t kid = g_handles[k].id;
        PyObject *kobj = g_handles[k].obj;
        g_handles[k].obj = NULL;
        g_handle_used--;
        size_t m = ht_hash_i64(kid) & (g_handle_cap - 1);
        while (g_handles[m].obj != NULL)
            m = (m + 1) & (g_handle_cap - 1);
        g_handles[m].id = kid;
        g_handles[m].obj = kobj;
        g_handle_used++;
        k = (k + 1) & (g_handle_cap - 1);
    }
    return 1;
}

static void ht_clear(void)
{
    if (g_handles != NULL) {
        for (size_t i = 0; i < g_handle_cap; i++)
            Py_XDECREF(g_handles[i].obj);
        free(g_handles);
        g_handles = NULL;
    }
    free(g_rev);
    g_rev = NULL;
    g_handle_cap = g_rev_cap = g_handle_used = g_rev_used = 0;
}

/* --- утилиты json -------------------------------------------------------- */

/* json.dumps(obj, ensure_ascii=False) -> str (новая ссылка). */
static PyObject *json_dumps_obj(PyObject *obj)
{
    PyObject *args = PyTuple_Pack(1, obj);
    if (args == NULL)
        return NULL;
    PyObject *s = PyObject_Call(g_json_dumps, args, g_dumps_kw);
    Py_DECREF(args);
    return s;
}

/* obj -> malloc()-C-строка UTF-8 JSON (для mock-колбэков). NULL при ошибке. */
static char *json_dups_obj(PyObject *obj)
{
    PyObject *s = json_dumps_obj(obj);
    if (s == NULL)
        return NULL;
    PyObject *b = PyUnicode_AsUTF8String(s);
    Py_DECREF(s);
    if (b == NULL)
        return NULL;
    char *out = dup_cstr(PyBytes_AsString(b), PyBytes_GET_SIZE(b));
    Py_DECREF(b);
    if (out == NULL)
        PyErr_NoMemory();
    return out;
}

/* C-строка -> объект Python через json.loads (новая ссылка). */
static PyObject *json_loads_cstr(const char *cstr, Py_ssize_t n)
{
    PyObject *b = PyBytes_FromStringAndSize(cstr, n);
    if (b == NULL)
        return NULL;
    PyObject *obj = PyObject_CallOneArg(g_json_loads, b);
    Py_DECREF(b);
    return obj;
}

/* str -> C-строка UTF-8 (borrowed; *tmp держит промежуточный bytes, либо
 * NULL — тогда источник сам живёт до конца использования). */
static const char *as_cutf8(PyObject *uni, PyObject **tmp)
{
    *tmp = NULL;
    if (PyBytes_Check(uni))
        return PyBytes_AsString(uni);
    PyObject *b = PyUnicode_AsUTF8String(uni);
    if (b == NULL)
        return NULL;
    *tmp = b;
    return PyBytes_AsString(b);
}

/* =========================================================================
 * BridgeBackend
 * ========================================================================= */

typedef struct {
    PyObject_HEAD
    PyObject *service;   /* str: префикс сервиса, напр. "java" */
    PyObject *fields;    /* dict: fqcn -> frozenset(полей) из манифеста */
    PyObject *classes;   /* set известных fqcn (class_exists) */
} BridgeBackendObject;

/* --- манифест ------------------------------------------------------------- */

static int bb_load_manifest(BridgeBackendObject *self, PyObject *path_obj)
{
    PyObject *path_unref = NULL;

    if (path_obj != NULL && path_obj != Py_None) {
        path_unref = PyObject_Str(path_obj);
        if (path_unref == NULL)
            return -1;
    }
    else {
        const char *env = getenv("EXTERALESS_MANIFEST");
        if (env != NULL && env[0] != '\0')
            path_unref = PyUnicode_FromString(env);
        else if (g_default_manifest != NULL)
            path_unref = PyUnicode_FromString(g_default_manifest);
        if (path_unref == NULL) {
            /* манифеста нет — пустая поверхность (как MockBackend) */
            self->fields = PyDict_New();
            self->classes = PySet_New(NULL);
            return (self->fields != NULL && self->classes != NULL) ? 0 : -1;
        }
    }
    const char *path = PyUnicode_AsUTF8(path_unref);
    if (path == NULL) {
        Py_DECREF(path_unref);
        return -1;
    }

    FILE *fh = fopen(path, "rb");
    if (fh == NULL) {
        /* файла нет — честно пустая поверхность (зеркалит MockBackend) */
        Py_DECREF(path_unref);
        self->fields = PyDict_New();
        self->classes = PySet_New(NULL);
        if (self->fields == NULL || self->classes == NULL)
            return -1;
        return 0;
    }
    fseek(fh, 0, SEEK_END);
    long n = ftell(fh);
    fseek(fh, 0, SEEK_SET);
    char *buf = NULL;
    if (n > 0) {
        buf = (char *)malloc((size_t)n);
        if (buf == NULL || fread(buf, 1, (size_t)n, fh) != (size_t)n) {
            free(buf);
            fclose(fh);
            Py_DECREF(path_unref);
            PyErr_NoMemory();
            return -1;
        }
    }
    fclose(fh);

    PyObject *manifest = NULL;
    if (n > 0)
        manifest = json_loads_cstr(buf, (Py_ssize_t)n);
    free(buf);
    Py_DECREF(path_unref);
    if (manifest == NULL)
        return -1;   /* json-ошибка пробрасывается наверх честно */
    if (!PyDict_Check(manifest)) {
        Py_DECREF(manifest);
        return bridge_error("manifest: root is not an object");
    }

    PyObject *classes = PyDict_GetItemString(manifest, "classes");
    if (classes == NULL || !PyDict_Check(classes))
        classes = manifest;   /* допускаем плоский формат {fqcn: {...}} */

    PyObject *fields = PyDict_New();
    PyObject *known = PySet_New(NULL);
    if (fields == NULL || known == NULL) {
        Py_XDECREF(fields);
        Py_XDECREF(known);
        Py_DECREF(manifest);
        return -1;
    }

    int ok = 0;
    Py_ssize_t pos = 0;
    PyObject *fqcn = NULL, *entry = NULL;
    while (PyDict_Next(classes, &pos, &fqcn, &entry)) {
        if (!PyUnicode_Check(fqcn) || !PyDict_Check(entry))
            continue;
        if (PySet_Add(known, fqcn) < 0)
            goto done;
        PyObject *declared = PyDict_GetItemString(entry, "declared");
        if (declared == NULL || !PyDict_Check(declared))
            continue;
        PyObject *fl = PyDict_GetItemString(declared, "fields");
        if (fl == NULL || !PyList_Check(fl))
            continue;
        PyObject *fset = PySet_New(fl);
        if (fset == NULL)
            goto done;
        if (PyDict_SetItem(fields, fqcn, fset) < 0) {
            Py_DECREF(fset);
            goto done;
        }
        Py_DECREF(fset);
    }
    ok = 1;

done:
    Py_DECREF(manifest);
    if (ok) {
        self->fields = fields;
        self->classes = known;
        return 0;
    }
    Py_DECREF(fields);
    Py_DECREF(known);
    return -1;
}

/* --- маршаллинг ----------------------------------------------------------- */

/* Python-значение -> значение, готовое к json.dumps. Новый ref. */
static PyObject *marshal_value(PyObject *v)
{
    if (v == Py_None || PyBool_Check(v) || PyUnicode_Check(v) ||
        PyFloat_Check(v)) {
        return Py_NewRef(v);
    }
    if (PyLong_Check(v)) {
        int overflow = 0;
        long long ll = PyLong_AsLongLongAndOverflow(v, &overflow);
        if (overflow != 0) {
            PyErr_SetString(PyExc_OverflowError,
                            "bridge: int argument does not fit int64");
            return NULL;
        }
        if (ll == -1 && PyErr_Occurred())
            return NULL;
        return Py_NewRef(v);
    }
    if (PyList_Check(v) || PyTuple_Check(v)) {
        PyObject *out = PyList_New(PySequence_Size(v));
        if (out == NULL)
            return NULL;
        Py_ssize_t i = 0;
        PyObject *item = NULL;
        PyObject *iter = PyObject_GetIter(v);
        if (iter == NULL) {
            Py_DECREF(out);
            return NULL;
        }
        while ((item = PyIter_Next(iter)) != NULL) {
            PyObject *m = marshal_value(item);
            Py_DECREF(item);
            if (m == NULL) {
                Py_DECREF(iter);
                Py_DECREF(out);
                return NULL;
            }
            PyList_SET_ITEM(out, i, m);   /* крадёт ссылку */
            i++;
        }
        Py_DECREF(iter);
        if (PyErr_Occurred()) {
            Py_DECREF(out);
            return NULL;
        }
        return out;
    }
    if (PyDict_Check(v)) {
        PyObject *out = PyDict_New();
        if (out == NULL)
            return NULL;
        Py_ssize_t pos = 0;
        PyObject *key = NULL, *val = NULL;
        while (PyDict_Next(v, &pos, &key, &val)) {
            PyObject *k = PyUnicode_Check(key) ? Py_NewRef(key)
                                               : PyObject_Str(key);
            if (k == NULL) {
                Py_DECREF(out);
                return NULL;
            }
            PyObject *m = marshal_value(val);
            if (m == NULL || PyDict_SetItem(out, k, m) < 0) {
                Py_XDECREF(m);
                Py_DECREF(k);
                Py_DECREF(out);
                return NULL;
            }
            Py_DECREF(k);
            Py_DECREF(m);
        }
        return out;
    }
    /* прочий объект (JavaInstance, bytes, произвольный) — handle-маркер */
    int64_t id = ht_insert(v);
    if (id == 0)
        return NULL;
    PyObject *fqcn = PyObject_GetAttrString(v, "_fqcn");
    if (fqcn == NULL)
        PyErr_Clear();
    else if (!PyUnicode_Check(fqcn))
        Py_CLEAR(fqcn);
    PyObject *marker = PyDict_New();
    PyObject *id_obj = PyLong_FromLongLong(id);
    if (marker == NULL || id_obj == NULL ||
        PyDict_SetItemString(marker, "__handle__", id_obj) < 0 ||
        PyDict_SetItemString(marker, "__fqcn__",
                             fqcn != NULL ? fqcn : Py_None) < 0) {
        Py_XDECREF(id_obj);
        Py_XDECREF(marker);
        Py_XDECREF(fqcn);
        return NULL;
    }
    Py_DECREF(id_obj);
    Py_XDECREF(fqcn);
    return marker;
}

/* (args, kwargs) -> malloc()-C-строка UTF-8 {"args":[...],"kwargs":{...}}. */
static char *marshal_payload(PyObject *args, PyObject *kwargs)
{
    if (kwargs != NULL && kwargs != Py_None && !PyDict_Check(kwargs)) {
        PyErr_SetString(PyExc_TypeError, "bridge: kwargs must be a dict");
        return NULL;
    }
    PyObject *arglist = PyList_New(0);
    PyObject *kwdict = PyDict_New();
    if (arglist == NULL || kwdict == NULL) {
        Py_XDECREF(arglist);
        Py_XDECREF(kwdict);
        return NULL;
    }
    if (args != NULL && args != Py_None) {
        PyObject *iter = PyObject_GetIter(args);
        if (iter == NULL)
            goto fail;
        PyObject *item = NULL;
        while ((item = PyIter_Next(iter)) != NULL) {
            PyObject *m = marshal_value(item);
            Py_DECREF(item);
            int appended = m != NULL && PyList_Append(arglist, m) == 0;
            Py_XDECREF(m);
            if (!appended) {
                Py_DECREF(iter);
                goto fail;
            }
        }
        Py_DECREF(iter);
        if (PyErr_Occurred())
            goto fail;
    }
    if (kwargs != NULL && kwargs != Py_None) {
        Py_ssize_t pos = 0;
        PyObject *key = NULL, *val = NULL;
        while (PyDict_Next(kwargs, &pos, &key, &val)) {
            PyObject *k = PyUnicode_Check(key) ? Py_NewRef(key)
                                               : PyObject_Str(key);
            PyObject *m = marshal_value(val);
            int stored = k != NULL && m != NULL &&
                         PyDict_SetItem(kwdict, k, m) == 0;
            Py_XDECREF(k);
            Py_XDECREF(m);
            if (!stored)
                goto fail;
        }
    }
    {
        PyObject *payload = PyDict_New();
        char *out = NULL;
        if (payload != NULL &&
            PyDict_SetItemString(payload, "args", arglist) == 0 &&
            PyDict_SetItemString(payload, "kwargs", kwdict) == 0)
            out = json_dups_obj(payload);
        Py_XDECREF(payload);
        Py_DECREF(arglist);
        Py_DECREF(kwdict);
        return out;
    }

fail:
    Py_DECREF(arglist);
    Py_DECREF(kwdict);
    return NULL;
}

/* --- анмаршаллинг результата ---------------------------------------------- */

static PyObject *unmarshal_walk(BridgeBackendObject *self, PyObject *v);

static PyObject *unmarshal_dict(BridgeBackendObject *self, PyObject *dict)
{
    PyObject *err = PyDict_GetItemString(dict, "__error__");
    if (err != NULL) {
        PyObject *msg = PyObject_Str(err);
        if (msg == NULL)
            return NULL;
        bridge_error("bridge host error: %S", msg);
        Py_DECREF(msg);
        return NULL;
    }
    PyObject *id_obj = PyDict_GetItemString(dict, "__handle__");
    if (id_obj != NULL && PyLong_Check(id_obj)) {
        long long id = PyLong_AsLongLong(id_obj);
        if (id == -1 && PyErr_Occurred())
            return NULL;
        PyObject *existing = ht_resolve((int64_t)id);
        if (existing != NULL)
            return Py_NewRef(existing);   /* ТОТ ЖЕ объект */
        PyObject *fqcn = PyDict_GetItemString(dict, "__fqcn__");
        if (fqcn != NULL && PyUnicode_Check(fqcn) && g_JavaInstance != NULL) {
            PyObject *inst = PyObject_CallFunctionObjArgs(
                g_JavaInstance, fqcn, (PyObject *)self, NULL);
            if (inst == NULL)
                return NULL;
            if (ht_insert_with_id(inst, (int64_t)id) < 0) {
                Py_DECREF(inst);
                return NULL;
            }
            return inst;
        }
        bridge_error("bridge: dangling handle %lld", id);
        return NULL;
    }
    /* не маркер — обычный dict: проходим значения рекурсивно */
    PyObject *out = PyDict_New();
    if (out == NULL)
        return NULL;
    Py_ssize_t pos = 0;
    PyObject *key = NULL, *val = NULL;
    while (PyDict_Next(dict, &pos, &key, &val)) {
        PyObject *m = unmarshal_walk(self, val);
        if (m == NULL || PyDict_SetItem(out, key, m) < 0) {
            Py_XDECREF(m);
            Py_DECREF(out);
            return NULL;
        }
        Py_DECREF(m);
    }
    return out;
}

static PyObject *unmarshal_walk(BridgeBackendObject *self, PyObject *v)
{
    if (PyDict_Check(v))
        return unmarshal_dict(self, v);
    if (PyList_Check(v)) {
        PyObject *out = PyList_New(PyList_GET_SIZE(v));
        if (out == NULL)
            return NULL;
        for (Py_ssize_t i = 0; i < PyList_GET_SIZE(v); i++) {
            PyObject *m = unmarshal_walk(self, PyList_GET_ITEM(v, i));
            if (m == NULL) {
                Py_DECREF(out);
                return NULL;
            }
            PyList_SET_ITEM(out, i, m);
        }
        return out;
    }
    if (PyTuple_Check(v)) {
        PyObject *out = PyTuple_New(PyTuple_GET_SIZE(v));
        if (out == NULL)
            return NULL;
        for (Py_ssize_t i = 0; i < PyTuple_GET_SIZE(v); i++) {
            PyObject *m = unmarshal_walk(self, PyTuple_GET_ITEM(v, i));
            if (m == NULL) {
                Py_DECREF(out);
                return NULL;
            }
            PyTuple_SET_ITEM(out, i, m);
        }
        return out;
    }
    return Py_NewRef(v);
}

static PyObject *unmarshal_result(BridgeBackendObject *self, char *res)
{
    if (res == NULL)
        Py_RETURN_NONE;
    size_t n = strlen(res);
    if (n == 0) {
        free(res);
        Py_RETURN_NONE;
    }
    PyObject *parsed = json_loads_cstr(res, (Py_ssize_t)n);
    free(res);
    if (parsed == NULL)
        return NULL;
    PyObject *out = unmarshal_walk(self, parsed);
    Py_DECREF(parsed);
    return out;
}

/* --- резолв сервиса ------------------------------------------------------- */

static void *bb_resolve_op(BridgeBackendObject *self, int op)
{
    PyObject *name = PyUnicode_FromFormat("%U.%s", self->service,
                                          OP_SUFFIX[op]);
    if (name == NULL)
        return NULL;
    const char *c = PyUnicode_AsUTF8(name);
    void *fn = c != NULL ? registry_find(c) : NULL;
    Py_DECREF(name);
    if (fn == NULL)
        bridge_error("no bridge service registered for '%U.%s'",
                     self->service, OP_SUFFIX[op]);
    return fn;
}

/* fqcn инстанса: attr _fqcn, иначе type(obj).__name__ (как _target_of). */
static PyObject *instance_fqcn(PyObject *instance)
{
    PyObject *fqcn = PyObject_GetAttrString(instance, "_fqcn");
    if (fqcn != NULL)
        return fqcn;
    PyErr_Clear();
    PyObject *tp = PyObject_GetAttrString(instance, "__class__");
    if (tp == NULL)
        return NULL;
    fqcn = PyObject_GetAttrString(tp, "__name__");
    Py_DECREF(tp);
    return fqcn;
}

static int bb_class_known(BridgeBackendObject *self, PyObject *fqcn)
{
    return PySet_Contains(self->classes, fqcn);   /* 1/0/-1(ошибка) */
}

/* Вызов колбэка: GIL удерживается (контракт в шапке). После возврата
 * проверяем, не оставил ли колбэк мусорное исключение. */
static int bb_after_callback(int rc)
{
    if (PyErr_Occurred()) {
        /* колбэк вернулся с pending-исключением — это нарушение контракта;
         * превращаем в сбой вызова, не роняя интерпретатор */
        PyErr_Clear();
        return -1;
    }
    return rc != 0 ? -2 : 0;   /* -2 = rc != 0 */
}

/* --- типовые методы Backend ---------------------------------------------- */

static PyObject *bb_construct(BridgeBackendObject *self,
                              PyObject *const *fast, Py_ssize_t n)
{
    if (n != 2) {
        PyErr_SetString(PyExc_TypeError,
                        "construct(fqcn, args) takes exactly 2 arguments");
        return NULL;
    }
    PyObject *fqcn = fast[0];
    PyObject *args = fast[1];
    if (!PyUnicode_Check(fqcn)) {
        PyErr_SetString(PyExc_TypeError, "construct: fqcn must be str");
        return NULL;
    }
    int known = bb_class_known(self, fqcn);
    if (known < 0)
        return NULL;
    if (!known) {
        bridge_error("no class %R", fqcn);
        return NULL;
    }
    char *payload = marshal_payload(args, NULL);
    if (payload == NULL)
        return NULL;
    xt_construct_fn fn = (xt_construct_fn)bb_resolve_op(self, OP_CONSTRUCT);
    PyObject *tmp = NULL;
    const char *fqcn_c = fn != NULL ? as_cutf8(fqcn, &tmp) : NULL;
    if (fn == NULL || fqcn_c == NULL) {
        free(payload);
        Py_XDECREF(tmp);
        return NULL;
    }
    char *res = NULL;
    int rc = fn(fqcn_c, payload, &res);   /* GIL удержан (см. шапку) */
    free(payload);
    Py_XDECREF(tmp);
    int bad = bb_after_callback(rc);
    if (bad == -1) {
        free(res);
        bridge_error("bridge service '%U.construct' left a pending exception",
                     self->service);
        return NULL;
    }
    if (bad == -2) {
        free(res);
        bridge_error("bridge service '%U.construct' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    return unmarshal_result(self, res);
}

static PyObject *bb_call(BridgeBackendObject *self,
                         PyObject *const *fast, Py_ssize_t n,
                         PyObject *kwnames)
{
    if (kwnames != NULL || n != 4) {
        PyErr_SetString(PyExc_TypeError,
                        "call(fqcn, member, args, kwargs) takes 4 positional "
                        "arguments");
        return NULL;
    }
    PyObject *fqcn = fast[0], *member = fast[1], *args = fast[2],
             *kwargs = fast[3];
    if (!PyUnicode_Check(fqcn) || !PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "call: fqcn/member must be str");
        return NULL;
    }
    int known = bb_class_known(self, fqcn);
    if (known < 0)
        return NULL;
    if (!known) {
        bridge_error("no class %R", fqcn);
        return NULL;
    }
    char *payload = marshal_payload(args, kwargs);
    if (payload == NULL)
        return NULL;
    xt_call_fn fn = (xt_call_fn)bb_resolve_op(self, OP_CALL);
    PyObject *t1 = NULL, *t2 = NULL;
    const char *fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    const char *member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        free(payload);
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    char *res = NULL;
    int rc = fn(fqcn_c, member_c, payload, &res);
    free(payload);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    int bad = bb_after_callback(rc);
    if (bad == -1) {
        free(res);
        bridge_error("bridge service '%U.call' left a pending exception",
                     self->service);
        return NULL;
    }
    if (bad == -2) {
        free(res);
        bridge_error("bridge service '%U.call' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    return unmarshal_result(self, res);
}

static PyObject *bb_call_instance(BridgeBackendObject *self,
                                  PyObject *const *fast, Py_ssize_t n,
                                  PyObject *kwnames)
{
    if (kwnames != NULL || n != 4) {
        PyErr_SetString(PyExc_TypeError,
                        "call_instance(instance, member, args, kwargs) takes "
                        "4 positional arguments");
        return NULL;
    }
    PyObject *instance = fast[0], *member = fast[1], *args = fast[2],
             *kwargs = fast[3];
    if (!PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "call_instance: member must be str");
        return NULL;
    }
    int64_t handle = ht_insert(instance);
    if (handle == 0)
        return NULL;
    PyObject *fqcn = instance_fqcn(instance);
    if (fqcn == NULL)
        return NULL;
    char *payload = marshal_payload(args, kwargs);
    if (payload == NULL) {
        Py_DECREF(fqcn);
        return NULL;
    }
    xt_call_instance_fn fn =
        (xt_call_instance_fn)bb_resolve_op(self, OP_CALL_INSTANCE);
    PyObject *t1 = NULL, *t2 = NULL;
    const char *fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    const char *member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        free(payload);
        Py_DECREF(fqcn);
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    char *res = NULL;
    int rc = fn(handle, fqcn_c, member_c, payload, &res);
    free(payload);
    Py_DECREF(fqcn);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    int bad = bb_after_callback(rc);
    if (bad == -1) {
        free(res);
        bridge_error("bridge service '%U.call_instance' left a pending "
                     "exception", self->service);
        return NULL;
    }
    if (bad == -2) {
        free(res);
        bridge_error("bridge service '%U.call_instance' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    return unmarshal_result(self, res);
}

static PyObject *bb_get(BridgeBackendObject *self,
                        PyObject *const *fast, Py_ssize_t n)
{
    if (n != 2) {
        PyErr_SetString(PyExc_TypeError,
                        "get(fqcn, member) takes 2 arguments");
        return NULL;
    }
    PyObject *fqcn = fast[0], *member = fast[1];
    if (!PyUnicode_Check(fqcn) || !PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "get: fqcn/member must be str");
        return NULL;
    }
    xt_get_fn fn = (xt_get_fn)bb_resolve_op(self, OP_GET);
    PyObject *t1 = NULL, *t2 = NULL;
    const char *fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    const char *member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    char *res = NULL;
    int rc = fn(fqcn_c, member_c, &res);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    int bad = bb_after_callback(rc);
    if (bad == -1) {
        free(res);
        bridge_error("bridge service '%U.get' left a pending exception",
                     self->service);
        return NULL;
    }
    if (bad == -2) {
        free(res);
        bridge_error("bridge service '%U.get' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    return unmarshal_result(self, res);
}

static PyObject *bb_get_instance(BridgeBackendObject *self,
                                 PyObject *const *fast, Py_ssize_t n)
{
    if (n != 2) {
        PyErr_SetString(PyExc_TypeError,
                        "get_instance(instance, member) takes 2 arguments");
        return NULL;
    }
    PyObject *instance = fast[0], *member = fast[1];
    if (!PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "get_instance: member must be str");
        return NULL;
    }
    int64_t handle = ht_insert(instance);
    if (handle == 0)
        return NULL;
    PyObject *fqcn = instance_fqcn(instance);
    if (fqcn == NULL)
        return NULL;
    xt_get_instance_fn fn =
        (xt_get_instance_fn)bb_resolve_op(self, OP_GET_INSTANCE);
    PyObject *t1 = NULL, *t2 = NULL;
    const char *fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    const char *member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        Py_DECREF(fqcn);
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    char *res = NULL;
    int rc = fn(handle, fqcn_c, member_c, &res);
    Py_DECREF(fqcn);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    int bad = bb_after_callback(rc);
    if (bad == -1) {
        free(res);
        bridge_error("bridge service '%U.get_instance' left a pending "
                     "exception", self->service);
        return NULL;
    }
    if (bad == -2) {
        free(res);
        bridge_error("bridge service '%U.get_instance' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    return unmarshal_result(self, res);
}

static PyObject *bb_set(BridgeBackendObject *self,
                        PyObject *const *fast, Py_ssize_t n)
{
    if (n != 3) {
        PyErr_SetString(PyExc_TypeError,
                        "set(fqcn, member, value) takes 3 arguments");
        return NULL;
    }
    PyObject *fqcn = fast[0], *member = fast[1], *value = fast[2];
    if (!PyUnicode_Check(fqcn) || !PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "set: fqcn/member must be str");
        return NULL;
    }
    PyObject *m = marshal_value(value);
    if (m == NULL)
        return NULL;
    char *payload = json_dups_obj(m);
    Py_DECREF(m);
    if (payload == NULL)
        return NULL;
    xt_set_fn fn = (xt_set_fn)bb_resolve_op(self, OP_SET);
    PyObject *t1 = NULL, *t2 = NULL;
    const char *fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    const char *member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        free(payload);
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    int rc = fn(fqcn_c, member_c, payload);
    free(payload);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    int bad = bb_after_callback(rc);
    if (bad == -1) {
        bridge_error("bridge service '%U.set' left a pending exception",
                     self->service);
        return NULL;
    }
    if (bad == -2) {
        bridge_error("bridge service '%U.set' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bb_set_instance(BridgeBackendObject *self,
                                 PyObject *const *fast, Py_ssize_t n)
{
    if (n != 3) {
        PyErr_SetString(PyExc_TypeError,
                        "set_instance(instance, member, value) takes 3 "
                        "arguments");
        return NULL;
    }
    PyObject *instance = fast[0], *member = fast[1], *value = fast[2];
    if (!PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "set_instance: member must be str");
        return NULL;
    }
    int64_t handle = ht_insert(instance);
    if (handle == 0)
        return NULL;
    PyObject *fqcn = instance_fqcn(instance);
    if (fqcn == NULL)
        return NULL;
    PyObject *m = marshal_value(value);
    if (m == NULL) {
        Py_DECREF(fqcn);
        return NULL;
    }
    char *payload = json_dups_obj(m);
    Py_DECREF(m);
    if (payload == NULL) {
        Py_DECREF(fqcn);
        return NULL;
    }
    xt_set_instance_fn fn =
        (xt_set_instance_fn)bb_resolve_op(self, OP_SET_INSTANCE);
    PyObject *t1 = NULL, *t2 = NULL;
    const char *fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    const char *member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        free(payload);
        Py_DECREF(fqcn);
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    int rc = fn(handle, fqcn_c, member_c, payload);
    free(payload);
    Py_DECREF(fqcn);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    int bad = bb_after_callback(rc);
    if (bad == -1) {
        bridge_error("bridge service '%U.set_instance' left a pending "
                     "exception", self->service);
        return NULL;
    }
    if (bad == -2) {
        bridge_error("bridge service '%U.set_instance' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bb_member_kind(BridgeBackendObject *self,
                                PyObject *const *fast, Py_ssize_t n)
{
    if (n != 2) {
        PyErr_SetString(PyExc_TypeError,
                        "member_kind(fqcn, member) takes 2 arguments");
        return NULL;
    }
    PyObject *fqcn = fast[0], *member = fast[1];
    PyObject *fset = PyDict_GetItemWithError(self->fields, fqcn);
    if (fset == NULL) {
        if (PyErr_Occurred())
            return NULL;
        return PyUnicode_FromString("unknown");
    }
    int r = PySequence_Contains(fset, member);
    if (r < 0)
        return NULL;
    return PyUnicode_FromString(r ? "field" : "method");
}

static PyObject *bb_class_exists(BridgeBackendObject *self,
                                 PyObject *const *fast, Py_ssize_t n)
{
    if (n != 1) {
        PyErr_SetString(PyExc_TypeError,
                        "class_exists(fqcn) takes 1 argument");
        return NULL;
    }
    if (!PyUnicode_Check(fast[0])) {
        PyErr_SetString(PyExc_TypeError, "class_exists: fqcn must be str");
        return NULL;
    }
    int r = bb_class_known(self, fast[0]);
    if (r < 0)
        return NULL;
    return PyBool_FromLong(r);
}

/* --- lifecycle ------------------------------------------------------------ */

static int bb_init(BridgeBackendObject *self, PyObject *args, PyObject *kwds)
{
    static char *kwlist[] = {"service", "manifest_path", NULL};
    PyObject *service = NULL, *manifest_path = NULL;
    if (!PyArg_ParseTupleAndKeywords(args, kwds, "|OO", kwlist,
                                      &service, &manifest_path))
        return -1;
    PyObject *svc;
    if (service == NULL || service == Py_None)
        svc = PyUnicode_FromString("java");
    else
        svc = PyObject_Str(service);
    if (svc == NULL)
        return -1;
    Py_XSETREF(self->service, svc);
    Py_CLEAR(self->fields);
    Py_CLEAR(self->classes);
    if (bb_load_manifest(self, manifest_path) < 0)
        return -1;
    return 0;
}

static void bb_dealloc(BridgeBackendObject *self)
{
    Py_XDECREF(self->service);
    Py_XDECREF(self->fields);
    Py_XDECREF(self->classes);
    Py_TYPE(self)->tp_free((PyObject *)self);
}

static PyMethodDef bb_methods[] = {
    {"construct", (PyCFunction)bb_construct, METH_FASTCALL,
     "construct(fqcn, args) — new Fqcn(*args) через сервис <service>.construct"},
    {"call", (PyCFunction)bb_call, METH_FASTCALL | METH_KEYWORDS,
     "call(fqcn, member, args, kwargs) — статический вызов"},
    {"call_instance", (PyCFunction)bb_call_instance,
     METH_FASTCALL | METH_KEYWORDS,
     "call_instance(instance, member, args, kwargs) — вызов метода объекта"},
    {"get", (PyCFunction)bb_get, METH_FASTCALL,
     "get(fqcn, member) — чтение статического поля"},
    {"get_instance", (PyCFunction)bb_get_instance, METH_FASTCALL,
     "get_instance(instance, member) — чтение поля объекта"},
    {"set", (PyCFunction)bb_set, METH_FASTCALL,
     "set(fqcn, member, value) — запись статического поля"},
    {"set_instance", (PyCFunction)bb_set_instance, METH_FASTCALL,
     "set_instance(instance, member, value) — запись поля объекта"},
    {"member_kind", (PyCFunction)bb_member_kind, METH_FASTCALL,
     "member_kind(fqcn, member) -> 'field' | 'method' | 'unknown' (манифест)"},
    {"class_exists", (PyCFunction)bb_class_exists, METH_FASTCALL,
     "class_exists(fqcn) -> bool (по манифесту)"},
    {NULL, NULL, 0, NULL}
};

static PyTypeObject BridgeBackendType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "_exteraless_bridge.BridgeBackend",
    .tp_doc = "C-реализация Backend: вызовы уходят в реестр сервисов "
              "xt_register_service. Протокол — см. python/virtualjava/backend.py",
    .tp_basicsize = sizeof(BridgeBackendObject),
    .tp_itemsize = 0,
    .tp_flags = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_BASETYPE,
    .tp_new = PyType_GenericNew,
    .tp_init = (initproc)bb_init,
    .tp_dealloc = (destructor)bb_dealloc,
    .tp_methods = bb_methods,
};

/* =========================================================================
 * встроенный mock-сервис (Windows/тесты): зеркалит MockBackend
 * ========================================================================= */

/* Запись в лог: поглощает ссылки на args/kwargs (может быть NULL). */
static int mock_note(const char *op, const char *fqcn, const char *member,
                     int64_t handle, PyObject *args, PyObject *kwargs)
{
    if (g_mock_log == NULL ||
        PyList_GET_SIZE(g_mock_log) >= XT_MOCK_LOG_CAP) {
        Py_XDECREF(args);
        Py_XDECREF(kwargs);
        return 0;   /* переполнение лога молча игнорируем (ограничение) */
    }
    PyObject *rec = PyDict_New();
    if (rec == NULL) {
        Py_XDECREF(args);
        Py_XDECREF(kwargs);
        return -1;
    }
    int ok = 1;
    PyObject *v;
    v = PyUnicode_FromString(op);
    ok = ok && v != NULL && PyDict_SetItemString(rec, "op", v) == 0;
    Py_XDECREF(v);
    if (ok) {
        v = PyUnicode_FromString(fqcn);
        ok = v != NULL && PyDict_SetItemString(rec, "fqcn", v) == 0;
        Py_XDECREF(v);
    }
    if (ok) {
        v = PyUnicode_FromString(member);
        ok = v != NULL && PyDict_SetItemString(rec, "member", v) == 0;
        Py_XDECREF(v);
    }
    if (ok && handle != 0) {
        v = PyLong_FromLongLong(handle);
        ok = v != NULL && PyDict_SetItemString(rec, "handle", v) == 0;
        Py_XDECREF(v);
    }
    if (ok && args != NULL)
        ok = PyDict_SetItemString(rec, "args", args) == 0;
    if (ok && kwargs != NULL)
        ok = PyDict_SetItemString(rec, "kwargs", kwargs) == 0;
    Py_XDECREF(args);
    Py_XDECREF(kwargs);
    if (!ok) {
        Py_DECREF(rec);
        return -1;
    }
    int appended = PyList_Append(g_mock_log, rec) == 0;
    Py_DECREF(rec);
    return appended ? 0 : -1;
}

/* {"args":[...],"kwargs":{...}} -> (args, kwargs); ошибки глотаем. */
static void mock_parse_payload(const char *json_args, PyObject **out_args,
                               PyObject **out_kwargs)
{
    *out_args = NULL;
    *out_kwargs = NULL;
    if (json_args == NULL)
        return;
    PyObject *obj = json_loads_cstr(json_args, (Py_ssize_t)strlen(json_args));
    if (obj == NULL) {
        PyErr_Clear();
        return;
    }
    if (PyDict_Check(obj)) {
        PyObject *a = PyDict_GetItemString(obj, "args");
        PyObject *k = PyDict_GetItemString(obj, "kwargs");
        if (a != NULL)
            *out_args = Py_NewRef(a);
        if (k != NULL)
            *out_kwargs = Py_NewRef(k);
    }
    Py_DECREF(obj);
}

/* Локальный сбой внутри mock: очистить исключение, вернуть rc=1. */
static int mock_fail(char **json_result)
{
    PyErr_Clear();
    *json_result = NULL;
    return 1;
}

/* mock: construct -> новый host-handle (< 0) + fqcn. */
static int mock_construct(const char *fqcn, const char *json_args,
                          char **json_result)
{
    PyObject *a = NULL, *k = NULL;
    mock_parse_payload(json_args, &a, &k);
    int64_t h = g_mock_next_handle--;
    if (mock_note("construct", fqcn, "<init>", h, a, k) < 0)
        return mock_fail(json_result);
    PyObject *res = PyDict_New();
    PyObject *hid = PyLong_FromLongLong(h);
    PyObject *fq = PyUnicode_FromString(fqcn);
    int ok = res != NULL && hid != NULL && fq != NULL &&
             PyDict_SetItemString(res, "__handle__", hid) == 0 &&
             PyDict_SetItemString(res, "__fqcn__", fq) == 0;
    Py_XDECREF(hid);
    Py_XDECREF(fq);
    if (!ok) {
        Py_XDECREF(res);
        return mock_fail(json_result);
    }
    *json_result = json_dups_obj(res);
    Py_DECREF(res);
    if (*json_result == NULL)
        return mock_fail(json_result);
    return 0;
}

/* mock: echoFirst — вернуть первый аргумент как есть (проверка identity). */
static int mock_echo_first(const char *json_args, char **json_result)
{
    PyObject *obj = json_loads_cstr(json_args, (Py_ssize_t)strlen(json_args));
    if (obj == NULL)
        return mock_fail(json_result);
    PyObject *val = NULL;
    if (PyDict_Check(obj)) {
        PyObject *args = PyDict_GetItemString(obj, "args");
        if (args != NULL && PyList_Check(args) && PyList_GET_SIZE(args) > 0)
            val = Py_NewRef(PyList_GET_ITEM(args, 0));
    }
    if (val == NULL)
        val = Py_NewRef(Py_None);
    char *out = json_dups_obj(val);
    Py_DECREF(val);
    Py_DECREF(obj);
    if (out == NULL)
        return mock_fail(json_result);
    *json_result = out;
    return 0;
}

static int mock_str_result(const char *prefix, const char *fqcn,
                           const char *member, char **json_result)
{
    PyObject *s = PyUnicode_FromFormat("%s%s#%s", prefix, fqcn, member);
    if (s == NULL)
        return mock_fail(json_result);
    *json_result = json_dups_obj(s);
    Py_DECREF(s);
    if (*json_result == NULL)
        return mock_fail(json_result);
    return 0;
}

static int mock_call(const char *fqcn, const char *member,
                     const char *json_args, char **json_result)
{
    if (strcmp(member, "echoFirst") == 0)
        return mock_echo_first(json_args, json_result);
    PyObject *a = NULL, *k = NULL;
    mock_parse_payload(json_args, &a, &k);
    if (mock_note("call", fqcn, member, 0, a, k) < 0)
        return mock_fail(json_result);
    return mock_str_result("result:", fqcn, member, json_result);
}

static int mock_call_instance(int64_t handle, const char *fqcn,
                              const char *member, const char *json_args,
                              char **json_result)
{
    if (strcmp(member, "echoFirst") == 0)
        return mock_echo_first(json_args, json_result);
    PyObject *a = NULL, *k = NULL;
    mock_parse_payload(json_args, &a, &k);
    if (mock_note("call_instance", fqcn, member, handle, a, k) < 0)
        return mock_fail(json_result);
    return mock_str_result("result:", fqcn, member, json_result);
}

static int mock_get(const char *fqcn, const char *member, char **json_result)
{
    if (mock_note("get", fqcn, member, 0, NULL, NULL) < 0)
        return mock_fail(json_result);
    return mock_str_result("field:", fqcn, member, json_result);
}

static int mock_get_instance(int64_t handle, const char *fqcn,
                             const char *member, char **json_result)
{
    if (mock_note("get_instance", fqcn, member, handle, NULL, NULL) < 0)
        return mock_fail(json_result);
    return mock_str_result("field:", fqcn, member, json_result);
}

static int mock_set(const char *fqcn, const char *member,
                    const char *json_value)
{
    PyObject *v = NULL;
    if (json_value != NULL)
        v = json_loads_cstr(json_value, (Py_ssize_t)strlen(json_value));
    if (v == NULL)
        PyErr_Clear();
    if (mock_note("set", fqcn, member, 0, v, NULL) < 0) {
        PyErr_Clear();
        return 1;
    }
    return 0;
}

static int mock_set_instance(int64_t handle, const char *fqcn,
                             const char *member, const char *json_value)
{
    PyObject *v = NULL;
    if (json_value != NULL)
        v = json_loads_cstr(json_value, (Py_ssize_t)strlen(json_value));
    if (v == NULL)
        PyErr_Clear();
    if (mock_note("set_instance", fqcn, member, handle, v, NULL) < 0) {
        PyErr_Clear();
        return 1;
    }
    PyErr_Clear();
    return 0;
}

/* =========================================================================
 * Python-видимое API модуля
 * ========================================================================= */

static PyObject *py_xt_register_service(PyObject *self, PyObject *args)
{
    const char *name;
    PyObject *ptr;
    if (!PyArg_ParseTuple(args, "sO", &name, &ptr))
        return NULL;
    void *fn = PyLong_AsVoidPtr(ptr);
    if (fn == NULL) {
        if (PyErr_Occurred())
            return NULL;
        PyErr_SetString(PyExc_ValueError,
                        "xt_register_service: null pointer");
        return NULL;
    }
    if (registry_upsert(name, fn) < 0)
        return NULL;
    Py_RETURN_NONE;
}

static PyObject *py_xt_unregister_service(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name))
        return NULL;
    return PyBool_FromLong(registry_remove(name));
}

static PyObject *py_xt_service_ptr(PyObject *self, PyObject *args)
{
    const char *name;
    if (!PyArg_ParseTuple(args, "s", &name))
        return NULL;
    return PyLong_FromVoidPtr(registry_find(name));
}

static PyObject *py_xt_install_mock_service(PyObject *self, PyObject *args,
                                            PyObject *kwds)
{
    static char *kwlist[] = {"prefix", NULL};
    const char *prefix = "java";
    if (!PyArg_ParseTupleAndKeywords(args, kwds, "|s", kwlist, &prefix))
        return NULL;
    char name[XT_SERVICE_NAME_MAX];
    struct {
        const char *suffix;
        void *fn;
    } entries[] = {
        {"construct", (void *)mock_construct},
        {"call", (void *)mock_call},
        {"call_instance", (void *)mock_call_instance},
        {"get", (void *)mock_get},
        {"get_instance", (void *)mock_get_instance},
        {"set", (void *)mock_set},
        {"set_instance", (void *)mock_set_instance},
    };
    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        PyOS_snprintf(name, sizeof(name), "%s.%s", prefix, entries[i].suffix);
        if (registry_upsert(name, entries[i].fn) < 0)
            return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *py_xt_builtin_ptr(PyObject *self, PyObject *args)
{
    const char *op;
    if (!PyArg_ParseTuple(args, "s", &op))
        return NULL;
    void *fn = NULL;
    if (strcmp(op, "construct") == 0)
        fn = (void *)mock_construct;
    else if (strcmp(op, "call") == 0)
        fn = (void *)mock_call;
    else if (strcmp(op, "call_instance") == 0)
        fn = (void *)mock_call_instance;
    else if (strcmp(op, "get") == 0)
        fn = (void *)mock_get;
    else if (strcmp(op, "get_instance") == 0)
        fn = (void *)mock_get_instance;
    else if (strcmp(op, "set") == 0)
        fn = (void *)mock_set;
    else if (strcmp(op, "set_instance") == 0)
        fn = (void *)mock_set_instance;
    else {
        PyErr_Format(PyExc_ValueError, "unknown op '%s'", op);
        return NULL;
    }
    return PyLong_FromVoidPtr(fn);
}

static PyObject *py_xt_mock_log(PyObject *self, PyObject *noargs)
{
    return PyList_GetSlice(g_mock_log, 0, PyList_GET_SIZE(g_mock_log));
}

static PyObject *py_xt_mock_log_clear(PyObject *self, PyObject *noargs)
{
    PyList_SetSlice(g_mock_log, 0, PyList_GET_SIZE(g_mock_log), NULL);
    Py_RETURN_NONE;
}

static PyObject *py_xt_register_handle(PyObject *self, PyObject *obj)
{
    int64_t id = ht_insert(obj);
    if (id == 0)
        return NULL;
    return PyLong_FromLongLong(id);
}

static PyObject *py_xt_resolve_handle(PyObject *self, PyObject *arg)
{
    long long id = PyLong_AsLongLong(arg);
    if (id == -1 && PyErr_Occurred())
        return NULL;
    PyObject *obj = ht_resolve((int64_t)id);
    if (obj == NULL)
        Py_RETURN_NONE;
    return Py_NewRef(obj);
}

static PyObject *py_xt_release_handle(PyObject *self, PyObject *arg)
{
    long long id = PyLong_AsLongLong(arg);
    if (id == -1 && PyErr_Occurred())
        return NULL;
    return PyBool_FromLong(ht_remove((int64_t)id));
}

static PyObject *py_xt_handle_count(PyObject *self, PyObject *noargs)
{
    return PyLong_FromSize_t(g_handle_used);
}

static PyObject *py_xt_clear_handles(PyObject *self, PyObject *noargs)
{
    ht_clear();
    Py_RETURN_NONE;
}

static PyObject *py_xt_bind(PyObject *self, PyObject *args)
{
    PyObject *instance_cls, *error_cls;
    if (!PyArg_ParseTuple(args, "OO", &instance_cls, &error_cls))
        return NULL;
    if (!PyType_Check(instance_cls) || !PyType_Check(error_cls)) {
        PyErr_SetString(PyExc_TypeError, "xt_bind expects two classes");
        return NULL;
    }
    Py_XSETREF(g_JavaInstance, Py_NewRef(instance_cls));
    Py_XSETREF(g_JavaMemberError, Py_NewRef(error_cls));
    Py_RETURN_NONE;
}

static PyMethodDef module_methods[] = {
    {"xt_register_service", py_xt_register_service, METH_VARARGS,
     "xt_register_service(name, callback_ptr) — зарегистрировать C-колбэк "
     "(int-адрес) под именем '<prefix>.<op>'. Сигнатуры — см. шапку "
     "_exteraless_bridge.c."},
    {"xt_unregister_service", py_xt_unregister_service, METH_VARARGS,
     "xt_unregister_service(name) -> bool"},
    {"xt_service_ptr", py_xt_service_ptr, METH_VARARGS,
     "xt_service_ptr(name) -> int (0, если не зарегистрирован)"},
    {"xt_install_mock_service", (PyCFunction)py_xt_install_mock_service,
     METH_VARARGS | METH_KEYWORDS,
     "xt_install_mock_service(prefix='java') — встроенный C-mock (Windows, "
     "тесты): зеркалит MockBackend, поддерживает member='echoFirst'."},
    {"xt_builtin_ptr", py_xt_builtin_ptr, METH_VARARGS,
     "xt_builtin_ptr(op) -> int — адрес встроенной mock-функции (для "
     "перерегистрации под другим именем)."},
    {"xt_mock_log", py_xt_mock_log, METH_NOARGS,
     "xt_mock_log() -> list[dict] — журнал вызовов встроенного mock-сервиса"},
    {"xt_mock_log_clear", py_xt_mock_log_clear, METH_NOARGS,
     "xt_mock_log_clear() — очистить журнал mock-сервиса"},
    {"xt_register_handle", py_xt_register_handle, METH_O,
     "xt_register_handle(obj) -> int64 id (повторный вызов — тот же id)"},
    {"xt_resolve_handle", py_xt_resolve_handle, METH_O,
     "xt_resolve_handle(id) -> obj | None (тот же объект по тому же id)"},
    {"xt_release_handle", py_xt_release_handle, METH_O,
     "xt_release_handle(id) -> bool — убрать объект из handle-таблицы"},
    {"xt_handle_count", py_xt_handle_count, METH_NOARGS,
     "xt_handle_count() -> int"},
    {"xt_clear_handles", py_xt_clear_handles, METH_NOARGS,
     "xt_clear_handles() — сброс всей handle-таблицы (тесты)"},
    {"xt_bind", py_xt_bind, METH_VARARGS,
     "xt_bind(JavaInstance, JavaMemberError) — классы virtualjava; "
     "python.bridge вызывает автоматически при импорте пакета"},
    {NULL, NULL, 0, NULL}
};

/* =========================================================================
 * инициализация модуля (multi-phase init)
 * ========================================================================= */

static int compute_default_manifest(PyObject *module)
{
    PyObject *file = PyObject_GetAttrString(module, "__file__");
    if (file == NULL) {
        PyErr_Clear();
        return 0;
    }
    const char *f = PyUnicode_AsUTF8(file);
    if (f == NULL) {
        Py_DECREF(file);
        PyErr_Clear();
        return 0;
    }
    size_t len = strlen(f);
    char *buf = (char *)malloc(len + 64);
    if (buf == NULL) {
        Py_DECREF(file);
        return 0;   /* без дефолта обойдёмся (env-переменная) */
    }
    strcpy(buf, f);
    for (int i = 0; i < 3; i++) {
        char *sep = buf + strlen(buf);
        while (sep > buf && sep[-1] != '/' && sep[-1] != '\\')
            sep--;
        if (sep > buf)
            sep[-1] = '\0';
    }
    strcat(buf, "/build/compat/manifest.json");
    free(g_default_manifest);
    g_default_manifest = buf;
    Py_DECREF(file);
    return 0;
}

static int module_exec(PyObject *module)
{
    PyObject *json_mod = PyImport_ImportModule("json");
    if (json_mod == NULL)
        return -1;
    g_json_dumps = PyObject_GetAttrString(json_mod, "dumps");
    g_json_loads = PyObject_GetAttrString(json_mod, "loads");
    Py_DECREF(json_mod);
    if (g_json_dumps == NULL || g_json_loads == NULL)
        return -1;

    g_dumps_kw = PyDict_New();
    if (g_dumps_kw == NULL ||
        PyDict_SetItemString(g_dumps_kw, "ensure_ascii", Py_False) < 0)
        return -1;

    g_mock_log = PyList_New(0);
    if (g_mock_log == NULL)
        return -1;

    if (compute_default_manifest(module) < 0)
        return -1;

    if (PyType_Ready(&BridgeBackendType) < 0)
        return -1;
    if (PyModule_AddObjectRef(module, "BridgeBackend",
                              (PyObject *)&BridgeBackendType) < 0)
        return -1;

    PyModule_AddStringConstant(module, "__version__", "0.1.0");
    return 0;
}

static PyModuleDef_Slot module_slots[] = {
    {Py_mod_exec, module_exec},
    /* TODO (суб-интерпретаторы): добавить
       {Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED}
       после перевода глобального состояния в module state (см. шапку). */
    {0, NULL}
};

static PyModuleDef module_def = {
    PyModuleDef_HEAD_INIT,
    .m_name = "_exteraless_bridge",
    .m_doc = "C-мост virtual-java: BridgeBackend + реестр сервисов "
             "xt_register_service + handle-таблица. Контракт Swift — см. "
             "комментарий в _exteraless_bridge.c.",
    .m_size = 0,   /* per-module state пуст (реестр/handle — глобалы, TODO) */
    .m_methods = module_methods,
    .m_slots = module_slots,
};

PyMODINIT_FUNC PyInit__exteraless_bridge(void)
{
    return PyModuleDef_Init(&module_def);
}
