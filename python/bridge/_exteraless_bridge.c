/* _exteraless_bridge.c — C-мост virtual-java для iOS-порта exteraless (этап 2).
 *
 * Назначение: BridgeBackend — реализация протокола python.virtualjava.backend.Backend,
 * маршрутизирующая вызовы прокси в нативные (Swift/C) сервисы через реестр
 * колбэков. На iOS реестр наполняет Swift (один раз при старте), на Windows —
 * встроенный C-mock (xt_install_mock_service) и/или ctypes-колбэки из тестов.
 *
 * ============================ МАРШАЛЛИНГ ============================
 *   Python -> сервис (json_args / json_value, UTF-8 JSON):
 *     None/bool/int/str        — нативные JSON-значения (по значению);
 *     конечный float           — JSON-число;
 *     list/tuple/dict          — рекурсивно в JSON (kwargs всегда dict);
 *     bytes                    — тег {"__bytes__": "<base64>"} (ровно один ключ);
 *     float inf/-inf/nan       — тег {"__float__": "inf"|"-inf"|"nan"};
 *     JavaInstance и прочие объекты — маркер {"__handle__": <int64 id>,
 *                                "__fqcn": <str|null>}; объект кладётся в
 *                                handle-таблицу (id генерируется мостом, > 0);
 *     int за пределами int64   — ошибка (задокументированное ограничение).
 *   Сервис -> Python (json_result, UTF-8 JSON):
 *     любое JSON-значение; контейнеры проходятся рекурсивно;
 *     {"__bytes__": "<base64>"}       — bytes (RFC 4648, padding '=', без \n);
 *     {"__float__": "inf"|"-inf"|"nan"} — неконечный float;
 *     тег — словарь РОВНО с одним таким ключом; лишние поля => обычный dict
 *     (ключи зарезервированы только в этой форме, как __handle__/__error__);
 *     {"__handle__": id}              — объект из handle-таблицы ЭТОГО
 *                                        интерпретатора: тот же id => ТОТ ЖЕ
 *                                        объект (identity);
 *     {"__handle__": id, "__fqcn": F} — неизвестный id => JavaInstance(F,
 *                                        backend) регистрируется под id
 *                                        (хост создаёт объекты; Swift должен
 *                                        использовать id < 0, чтобы не
 *                                        пересекаться с мостом);
 *     {"__error__": "msg"}            — JavaMemberError(msg) (на любом уровне);
 *     прочее                          — как есть (str/int/float/bool/None/...).
 *   json.dumps вызывается с allow_nan=false: inf/nan не становятся токенами
 *   Infinity/NaN. Обе стороны моста (marshal и unmarshal) понимают теги;
 *   хост, который возвращает JSON как есть, получает исходное значение.
 *
 * ====================== РЕЕСТР СЕРВИСОВ (Swift-сторона) ======================
 *   Реестр C-указателей общий на процесс и защищён PyMutex (суб-интерпретаторы
 *   могут идти параллельно). Имя сервиса = "<prefix>.<op>", op из:
 *     construct | call | call_instance | get | get_instance | set | set_instance
 *   BridgeBackend(service="java") ищет "java.call" и т.д. Регистрация:
 *     xt_register_service(name, callback_ptr)   — ptr = int-адрес C-функции
 *     xt_unregister_service(name) -> bool
 *     xt_service_ptr(name) -> int
 *
 *   ОСВОБОЖДЕНИЕ HANDLE ХОСТОМ (Swift -> мост, не операция Backend):
 *     int xt_host_release_handle(int64_t handle);
 *     Адрес: xt_builtin_ptr("release_handle").
 *     GIL можно не держать: функция берёт его через PyGILState_Ensure.
 *     Поток без thread state привяжется к главному интерпретатору, поэтому
 *     Swift зовёт её с потока, у которого уже есть thread state нужного
 *     интерпретатора (колбэк моста или тот же поток, что держит GIL).
 *     Возврат: 1 — слот освобождён, 0 — такого id нет, -1 — ошибка
 *     (при -1 выставлено Python-исключение).
 *     Чужой интерпретатор / чужой xt_set_interpreter_id этот id не видит
 *     и не освобождает.
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
 *   считает сбоем вызова). Handle-таблица мутируется только под GIL своего
 *   интерпретатора. Реестр сервисов — под PyMutex (GIL на время ожидания
 *   замка может быть отпущен, поэтому имена копируются в стек до захвата).
 *
 * ======================= СУБ-ИНТЕРПРЕТАТОРЫ (PEP 684) ========================
 *   m_size = sizeof(xt_state). У каждого интерпретатора свой module state:
 *   handle-таблицы, классы virtualjava, кэш json, mock-лог, путь манифеста.
 *   Слоты: Py_MOD_PER_INTERPRETER_GIL_SUPPORTED и Py_MOD_GIL_USED.
 *   Реестр Swift-колбэков общий (это указатели на функции, не объекты).
 *   Внутри одного интерпретатора xt_set_interpreter_id(id) выбирает отдельную
 *   таблицу; по умолчанию id = PyInterpreterState_GetID(). Два id не делят
 *   слоты. C-колбэки находят state текущего интерпретатора через капсулу в
 *   PyInterpreterState_GetDict (без цикла ссылок на объект модуля).
 *
 * Зависимости: CPython 3.12+; stdlib-модуль json (сериализация);
 * классы virtualjava.proxy.JavaInstance / virtualjava.backend.JavaMemberError
 * передаются в xt_bind из python/bridge/__init__.py (мост не знает путей
 * импорта хоста). Компилировать с /utf-8 (MSVC) — исходник в UTF-8.
 */

#define PY_SSIZE_T_CLEAN
#include <Python.h>

/* Python 3.12 не имеет PyMutex (появился в 3.13). Фолбэк — обычный
 * lock из pthread-слоя CPython; инициализация ленивая, чтобы не
 * зависеть от порядка инициализации модуля. */
#if PY_VERSION_HEX >= 0x030D0000
typedef PyMutex xt_mutex_t;
#  define XT_MUTEX_INIT {0}
static inline void xt_mutex_lock(xt_mutex_t *m) { PyMutex_Lock(m); }
static inline void xt_mutex_unlock(xt_mutex_t *m) { PyMutex_Unlock(m); }
#else
typedef PyThread_type_lock xt_mutex_t;
#  define XT_MUTEX_INIT NULL
static inline void xt_mutex_lock(xt_mutex_t *m) {
    if (*m == NULL) { *m = PyThread_allocate_lock(); }
    if (*m != NULL) { PyThread_acquire_lock(*m, WAIT_LOCK); }
}
static inline void xt_mutex_unlock(xt_mutex_t *m) {
    if (*m != NULL) { PyThread_release_lock(*m); }
}
#endif

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

/* ============================ состояние интерпретатора ================== */

#define XT_MAX_SERVICES 64
#define XT_SERVICE_NAME_MAX 160
#define XT_MAX_REALMS 32
#define XT_MOCK_LOG_CAP 4096
#define XT_STATE_CAPSULE "exteraless.bridge.state"
#define XT_STATE_DICT_KEY "_exteraless_bridge_state"

typedef struct {
    char name[XT_SERVICE_NAME_MAX];
    void *fn;
} ServiceEntry;

/* Реестр — процессный: указатели на C-функции, не объекты Python. */
static xt_mutex_t g_reg_mu = XT_MUTEX_INIT;
static ServiceEntry g_services[XT_MAX_SERVICES];
static int g_n_services = 0;

typedef struct xt_state xt_state;

/* Капсула в словаре интерпретатора. Не держит ссылку на модуль. */
typedef struct xt_anchor {
    xt_state *state;
} xt_anchor;

/* handle-таблица: int64 id -> PyObject* (owned). Открытая адресация.
 * Одна таблица = один interpreter id (реальный или xt_set_interpreter_id). */
typedef struct {
    int64_t id;
    PyObject *obj;   /* NULL = пусто */
} HandleSlot;

typedef struct {
    PyObject *obj;   /* NULL = пусто; без собственного INCREF */
    int64_t id;
} RevSlot;

typedef struct {
    int in_use;
    int64_t key;
    HandleSlot *handles;
    size_t handle_cap;
    size_t handle_used;
    RevSlot *rev;
    size_t rev_cap;
    size_t rev_used;
    int64_t next_handle;   /* мост раздаёт положительные id, старт с 1 */
} HandleRealm;

struct xt_state {
    HandleRealm realms[XT_MAX_REALMS];
    int64_t active_key;
    xt_anchor *anchor;

    PyObject *JavaInstance;
    PyObject *JavaMemberError;
    PyObject *json_dumps;
    PyObject *json_loads;
    PyObject *dumps_kw;
    PyObject *mock_log;
    int64_t mock_next_handle;   /* хостовые id < 0 */
    char *default_manifest;
};

/* =========================================================================
 * реестр сервисов
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

static int copy_service_name(const char *name, char *buf, size_t buflen)
{
    size_t n = strlen(name);
    if (n >= buflen)
        return -1;
    memcpy(buf, name, n + 1);
    return 0;
}

static void *registry_find(const char *name)
{
    char buf[XT_SERVICE_NAME_MAX];
    void *fn = NULL;
    if (copy_service_name(name, buf, sizeof(buf)) < 0)
        return NULL;
    xt_mutex_lock(&g_reg_mu);
    for (int i = 0; i < g_n_services; i++) {
        if (strcmp(g_services[i].name, buf) == 0) {
            fn = g_services[i].fn;
            break;
        }
    }
    xt_mutex_unlock(&g_reg_mu);
    return fn;
}

static int registry_upsert(const char *name, void *fn)
{
    char buf[XT_SERVICE_NAME_MAX];
    int rc = 0;
    if (strlen(name) >= XT_SERVICE_NAME_MAX) {
        PyErr_Format(PyExc_ValueError,
                     "xt_register_service: name too long: %.40s...", name);
        return -1;
    }
    memcpy(buf, name, strlen(name) + 1);
    xt_mutex_lock(&g_reg_mu);
    for (int i = 0; i < g_n_services; i++) {
        if (strcmp(g_services[i].name, buf) == 0) {
            g_services[i].fn = fn;
            xt_mutex_unlock(&g_reg_mu);
            return 0;
        }
    }
    if (g_n_services >= XT_MAX_SERVICES)
        rc = -1;
    else {
        memcpy(g_services[g_n_services].name, buf, strlen(buf) + 1);
        g_services[g_n_services].fn = fn;
        g_n_services++;
    }
    xt_mutex_unlock(&g_reg_mu);
    if (rc < 0) {
        PyErr_SetString(PyExc_RuntimeError,
                        "xt_register_service: registry is full "
                        "(XT_MAX_SERVICES)");
        return -1;
    }
    return 0;
}

static int registry_remove(const char *name)
{
    char buf[XT_SERVICE_NAME_MAX];
    int removed = 0;
    if (copy_service_name(name, buf, sizeof(buf)) < 0)
        return 0;
    xt_mutex_lock(&g_reg_mu);
    for (int i = 0; i < g_n_services; i++) {
        if (strcmp(g_services[i].name, buf) == 0) {
            g_services[i] = g_services[g_n_services - 1];
            g_n_services--;
            removed = 1;
            break;
        }
    }
    xt_mutex_unlock(&g_reg_mu);
    return removed;
}

/* =========================================================================
 * привязка state к интерпретатору
 * ========================================================================= */

static void xt_anchor_dtor(PyObject *cap)
{
    xt_anchor *anchor = (xt_anchor *)PyCapsule_GetPointer(cap, XT_STATE_CAPSULE);
    if (anchor == NULL) {
        PyErr_Clear();
        return;
    }
    if (anchor->state != NULL && anchor->state->anchor == anchor)
        anchor->state->anchor = NULL;
    anchor->state = NULL;
    PyMem_Free(anchor);
}

static int xt_anchor_install(PyObject *module, xt_state *st)
{
    PyInterpreterState *interp = PyInterpreterState_Get();
    PyObject *dict = interp != NULL ? PyInterpreterState_GetDict(interp) : NULL;
    xt_anchor *anchor;
    PyObject *cap;
    int rc;
    if (dict == NULL) {
        if (!PyErr_Occurred())
            PyErr_SetString(PyExc_RuntimeError,
                            "bridge: interpreter has no state dict");
        return -1;
    }
    anchor = (xt_anchor *)PyMem_Malloc(sizeof(*anchor));
    if (anchor == NULL) {
        PyErr_NoMemory();
        return -1;
    }
    anchor->state = st;
    st->anchor = anchor;
    cap = PyCapsule_New(anchor, XT_STATE_CAPSULE, xt_anchor_dtor);
    if (cap == NULL) {
        st->anchor = NULL;
        PyMem_Free(anchor);
        return -1;
    }
    rc = PyDict_SetItemString(dict, XT_STATE_DICT_KEY, cap);
    Py_DECREF(cap);
    if (rc < 0) {
        /* капсула при последнем DECREF вызовет dtor, если dict её не взял */
        return -1;
    }
    (void)module;
    return 0;
}

static xt_state *xt_state_get(void)
{
    PyInterpreterState *interp = PyInterpreterState_Get();
    PyObject *dict;
    PyObject *cap;
    xt_anchor *anchor;
    if (interp == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "bridge: no current interpreter");
        return NULL;
    }
    dict = PyInterpreterState_GetDict(interp);
    if (dict == NULL) {
        if (!PyErr_Occurred())
            PyErr_SetString(PyExc_RuntimeError,
                            "bridge: interpreter has no state dict");
        return NULL;
    }
    cap = PyDict_GetItemString(dict, XT_STATE_DICT_KEY);
    if (cap == NULL) {
        PyErr_SetString(PyExc_RuntimeError,
                        "bridge: not initialized in this interpreter");
        return NULL;
    }
    anchor = (xt_anchor *)PyCapsule_GetPointer(cap, XT_STATE_CAPSULE);
    if (anchor == NULL)
        return NULL;
    if (anchor->state == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "bridge: interpreter state was cleared");
        return NULL;
    }
    return anchor->state;
}

static xt_state *state_from_module(PyObject *module)
{
    xt_state *st;
    if (module != NULL && PyModule_Check(module)) {
        st = (xt_state *)PyModule_GetState(module);
        if (st != NULL)
            return st;
        PyErr_Clear();
    }
    return xt_state_get();
}

static xt_state *state_of_backend(PyObject *self)
{
    return (xt_state *)PyType_GetModuleState(Py_TYPE(self));
}

/* --- поднятие JavaMemberError ------------------------------------------- */

static int bridge_error(xt_state *st, const char *fmt, ...)
{
    va_list ap;
    PyObject *msg;
    PyObject *type;
    PyObject *exc;
    va_start(ap, fmt);
    msg = PyUnicode_FromFormatV(fmt, ap);
    va_end(ap);
    if (msg == NULL)
        return -1;
    type = (st != NULL && st->JavaMemberError != NULL) ? st->JavaMemberError
                                                       : PyExc_RuntimeError;
    exc = PyObject_CallOneArg(type, msg);
    Py_DECREF(msg);
    if (exc == NULL)
        return -1;
    PyErr_SetObject(type, exc);
    Py_DECREF(exc);
    return -1;
}

/* =========================================================================
 * handle-таблицы (все операции под GIL интерпретатора-владельца)
 * ========================================================================= */

static size_t ht_hash_i64(int64_t id)
{
    uint64_t x = (uint64_t)id;
    x = x * 0x9E3779B97F4A7C15ULL;
    return (size_t)(x >> 32);
}

static size_t ht_hash_ptr(void *p)
{
    return (size_t)((((uintptr_t)p >> 4) * 0x9E3779B97F4A7C15ULL) >> 24);
}

static HandleRealm *realm_find(xt_state *st, int64_t key)
{
    for (int i = 0; i < XT_MAX_REALMS; i++) {
        if (st->realms[i].in_use && st->realms[i].key == key)
            return &st->realms[i];
    }
    return NULL;
}

static HandleRealm *realm_create(xt_state *st, int64_t key)
{
    HandleRealm *existing = realm_find(st, key);
    HandleRealm *realm;
    if (existing != NULL)
        return existing;
    for (int i = 0; i < XT_MAX_REALMS; i++) {
        if (st->realms[i].in_use)
            continue;
        realm = &st->realms[i];
        memset(realm, 0, sizeof(*realm));
        realm->in_use = 1;
        realm->key = key;
        realm->next_handle = 1;
        return realm;
    }
    PyErr_SetString(PyExc_RuntimeError,
                    "bridge: too many interpreter handle tables");
    return NULL;
}

static HandleRealm *realm_current(xt_state *st)
{
    HandleRealm *realm = realm_find(st, st->active_key);
    if (realm != NULL)
        return realm;
    return realm_create(st, st->active_key);
}

static void realm_drop_entries(HandleRealm *realm)
{
    if (realm->handles != NULL) {
        for (size_t i = 0; i < realm->handle_cap; i++)
            Py_XDECREF(realm->handles[i].obj);
        free(realm->handles);
        realm->handles = NULL;
    }
    free(realm->rev);
    realm->rev = NULL;
    realm->handle_cap = realm->rev_cap = 0;
    realm->handle_used = realm->rev_used = 0;
    /* next_handle не сбрасываем: id не переиспользуются после clear */
}

static int ht_grow(HandleRealm *realm)
{
    size_t newcap = realm->handle_cap ? realm->handle_cap * 2 : 256;
    HandleSlot *nh = (HandleSlot *)calloc(newcap, sizeof(HandleSlot));
    RevSlot *nr = (RevSlot *)calloc(newcap, sizeof(RevSlot));
    if (nh == NULL || nr == NULL) {
        free(nh);
        free(nr);
        PyErr_NoMemory();
        return -1;
    }
    for (size_t i = 0; i < realm->handle_cap; i++) {
        size_t j;
        if (realm->handles[i].obj == NULL)
            continue;
        j = ht_hash_i64(realm->handles[i].id) & (newcap - 1);
        while (nh[j].obj != NULL)
            j = (j + 1) & (newcap - 1);
        nh[j] = realm->handles[i];
    }
    for (size_t i = 0; i < realm->rev_cap; i++) {
        size_t j;
        if (realm->rev[i].obj == NULL)
            continue;
        j = ht_hash_ptr(realm->rev[i].obj) & (newcap - 1);
        while (nr[j].obj != NULL)
            j = (j + 1) & (newcap - 1);
        nr[j] = realm->rev[i];
    }
    free(realm->handles);
    free(realm->rev);
    realm->handles = nh;
    realm->rev = nr;
    realm->handle_cap = newcap;
    realm->rev_cap = newcap;
    return 0;
}

static PyObject *ht_resolve(HandleRealm *realm, int64_t id)
{
    size_t j;
    if (realm->handle_cap == 0)
        return NULL;
    j = ht_hash_i64(id) & (realm->handle_cap - 1);
    for (size_t probes = 0; probes < realm->handle_cap; probes++) {
        if (realm->handles[j].obj == NULL)
            return NULL;
        if (realm->handles[j].id == id)
            return realm->handles[j].obj;
        j = (j + 1) & (realm->handle_cap - 1);
    }
    return NULL;
}

static int64_t ht_reverse_lookup(HandleRealm *realm, PyObject *obj)
{
    size_t j;
    if (realm->rev_cap == 0)
        return 0;
    j = ht_hash_ptr((void *)obj) & (realm->rev_cap - 1);
    for (size_t probes = 0; probes < realm->rev_cap; probes++) {
        if (realm->rev[j].obj == NULL)
            return 0;
        if (realm->rev[j].obj == obj)
            return realm->rev[j].id;
        j = (j + 1) & (realm->rev_cap - 1);
    }
    return 0;
}

static int64_t ht_insert(HandleRealm *realm, PyObject *obj)
{
    int64_t existing = ht_reverse_lookup(realm, obj);
    int64_t id;
    size_t j;
    size_t r;
    if (existing != 0)
        return existing;
    if (realm->handle_cap == 0 || realm->handle_used * 4 >= realm->handle_cap * 3) {
        if (ht_grow(realm) < 0)
            return 0;
    }
    id = realm->next_handle++;
    if (id == 0)
        id = realm->next_handle++;
    j = ht_hash_i64(id) & (realm->handle_cap - 1);
    while (realm->handles[j].obj != NULL)
        j = (j + 1) & (realm->handle_cap - 1);
    realm->handles[j].id = id;
    realm->handles[j].obj = Py_NewRef(obj);
    realm->handle_used++;

    r = ht_hash_ptr((void *)obj) & (realm->rev_cap - 1);
    while (realm->rev[r].obj != NULL)
        r = (r + 1) & (realm->rev_cap - 1);
    realm->rev[r].obj = obj;
    realm->rev[r].id = id;
    realm->rev_used++;
    return id;
}

static int ht_insert_with_id(HandleRealm *realm, PyObject *obj, int64_t id)
{
    size_t j;
    if (id == 0 || ht_resolve(realm, id) != NULL) {
        PyErr_Format(PyExc_ValueError, "handle %lld already used",
                     (long long)id);
        return -1;
    }
    if (realm->handle_cap == 0 || realm->handle_used * 4 >= realm->handle_cap * 3) {
        if (ht_grow(realm) < 0)
            return -1;
    }
    j = ht_hash_i64(id) & (realm->handle_cap - 1);
    while (realm->handles[j].obj != NULL)
        j = (j + 1) & (realm->handle_cap - 1);
    realm->handles[j].id = id;
    realm->handles[j].obj = Py_NewRef(obj);
    realm->handle_used++;

    if (ht_reverse_lookup(realm, obj) == 0) {
        size_t r = ht_hash_ptr((void *)obj) & (realm->rev_cap - 1);
        while (realm->rev[r].obj != NULL)
            r = (r + 1) & (realm->rev_cap - 1);
        realm->rev[r].obj = obj;
        realm->rev[r].id = id;
        realm->rev_used++;
    }
    return 0;
}

/* Удаление из открытой адресации: дырка ломает цепочку проб, поэтому
 * хвост кластера переставляется. Reverse-таблица — тоже. */
static void rev_remove(HandleRealm *realm, PyObject *obj, int64_t id)
{
    size_t j;
    if (realm->rev_cap == 0 || obj == NULL)
        return;
    j = ht_hash_ptr((void *)obj) & (realm->rev_cap - 1);
    for (size_t probes = 0; probes < realm->rev_cap; probes++) {
        size_t k;
        if (realm->rev[j].obj == NULL)
            return;
        if (realm->rev[j].obj != obj || realm->rev[j].id != id) {
            j = (j + 1) & (realm->rev_cap - 1);
            continue;
        }
        realm->rev[j].obj = NULL;
        realm->rev_used--;
        k = (j + 1) & (realm->rev_cap - 1);
        while (realm->rev[k].obj != NULL) {
            PyObject *kobj = realm->rev[k].obj;
            int64_t kid = realm->rev[k].id;
            size_t m;
            realm->rev[k].obj = NULL;
            realm->rev_used--;
            m = ht_hash_ptr((void *)kobj) & (realm->rev_cap - 1);
            while (realm->rev[m].obj != NULL)
                m = (m + 1) & (realm->rev_cap - 1);
            realm->rev[m].obj = kobj;
            realm->rev[m].id = kid;
            realm->rev_used++;
            k = (k + 1) & (realm->rev_cap - 1);
        }
        return;
    }
}

static int ht_remove(HandleRealm *realm, int64_t id)
{
    size_t j;
    size_t k;
    PyObject *obj;
    int found = 0;
    if (realm->handle_cap == 0)
        return 0;
    j = ht_hash_i64(id) & (realm->handle_cap - 1);
    for (size_t probes = 0; probes < realm->handle_cap; probes++) {
        if (realm->handles[j].obj == NULL)
            return 0;
        if (realm->handles[j].id == id) {
            found = 1;
            break;
        }
        j = (j + 1) & (realm->handle_cap - 1);
    }
    if (!found)
        return 0;
    obj = realm->handles[j].obj;
    realm->handles[j].obj = NULL;
    realm->handle_used--;
    k = (j + 1) & (realm->handle_cap - 1);
    while (realm->handles[k].obj != NULL) {
        int64_t kid = realm->handles[k].id;
        PyObject *kobj = realm->handles[k].obj;
        size_t m;
        realm->handles[k].obj = NULL;
        realm->handle_used--;
        m = ht_hash_i64(kid) & (realm->handle_cap - 1);
        while (realm->handles[m].obj != NULL)
            m = (m + 1) & (realm->handle_cap - 1);
        realm->handles[m].id = kid;
        realm->handles[m].obj = kobj;
        realm->handle_used++;
        k = (k + 1) & (realm->handle_cap - 1);
    }
    rev_remove(realm, obj, id);
    Py_DECREF(obj);
    return 1;
}

static int64_t realm_insert(xt_state *st, PyObject *obj)
{
    HandleRealm *realm = realm_current(st);
    if (realm == NULL)
        return 0;
    return ht_insert(realm, obj);
}

static PyObject *realm_resolve(xt_state *st, int64_t id)
{
    HandleRealm *realm = realm_current(st);
    if (realm == NULL)
        return NULL;
    return ht_resolve(realm, id);
}

/* =========================================================================
 * теги JSON: bytes и неконечные float
 *
 * JSON cannot represent bytes or non-finite floats. Both marshal and
 * unmarshal of this bridge understand exactly these one-key objects:
 *   {"__bytes__": "<base64>"}                  RFC 4648 with '=' padding,
 *                                              no newlines
 *   {"__float__": "inf" | "-inf" | "nan"}      non-finite floats
 * A dict with the same key plus any other field is a normal dict, not a tag.
 * Finite floats stay JSON numbers. json.dumps uses allow_nan=false so a
 * missed float cannot leak out as Infinity/NaN.
 * ========================================================================= */

static const char XT_B64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static int b64_digit(unsigned char c)
{
    if (c >= 'A' && c <= 'Z')
        return c - 'A';
    if (c >= 'a' && c <= 'z')
        return c - 'a' + 26;
    if (c >= '0' && c <= '9')
        return c - '0' + 52;
    if (c == '+')
        return 62;
    if (c == '/')
        return 63;
    return -1;
}

static PyObject *b64_encode(const unsigned char *src, Py_ssize_t len)
{
    Py_ssize_t out_len;
    char *buf;
    Py_ssize_t i = 0;
    Py_ssize_t j = 0;
    PyObject *text;
    if (len < 0) {
        PyErr_SetString(PyExc_ValueError, "bridge: negative bytes length");
        return NULL;
    }
    out_len = ((len + 2) / 3) * 4;
    buf = (char *)PyMem_Malloc((size_t)out_len + 1);
    if (buf == NULL) {
        PyErr_NoMemory();
        return NULL;
    }
    while (i + 2 < len) {
        unsigned n = ((unsigned)src[i] << 16) | ((unsigned)src[i + 1] << 8) |
                     (unsigned)src[i + 2];
        buf[j++] = XT_B64[(n >> 18) & 63];
        buf[j++] = XT_B64[(n >> 12) & 63];
        buf[j++] = XT_B64[(n >> 6) & 63];
        buf[j++] = XT_B64[n & 63];
        i += 3;
    }
    if (i < len) {
        unsigned n = (unsigned)src[i] << 16;
        if (i + 1 < len)
            n |= (unsigned)src[i + 1] << 8;
        buf[j++] = XT_B64[(n >> 18) & 63];
        buf[j++] = XT_B64[(n >> 12) & 63];
        if (i + 1 < len) {
            buf[j++] = XT_B64[(n >> 6) & 63];
            buf[j++] = '=';
        }
        else {
            buf[j++] = '=';
            buf[j++] = '=';
        }
    }
    text = PyUnicode_DecodeASCII(buf, j, "strict");
    PyMem_Free(buf);
    return text;
}

static PyObject *b64_decode(PyObject *text)
{
    Py_ssize_t n = 0;
    const char *s;
    Py_ssize_t out_len;
    PyObject *bytes;
    unsigned char *out;
    Py_ssize_t o = 0;
    if (!PyUnicode_Check(text)) {
        PyErr_SetString(PyExc_TypeError, "bridge: __bytes__ must be str");
        return NULL;
    }
    s = PyUnicode_AsUTF8AndSize(text, &n);
    if (s == NULL)
        return NULL;
    if (n == 0)
        return PyBytes_FromStringAndSize(NULL, 0);
    if (n % 4 != 0) {
        PyErr_SetString(PyExc_ValueError, "bridge: invalid __bytes__ base64");
        return NULL;
    }
    out_len = (n / 4) * 3;
    if (s[n - 1] == '=')
        out_len--;
    if (s[n - 2] == '=')
        out_len--;
    if (out_len < 0) {
        PyErr_SetString(PyExc_ValueError, "bridge: invalid __bytes__ base64");
        return NULL;
    }
    bytes = PyBytes_FromStringAndSize(NULL, out_len);
    if (bytes == NULL)
        return NULL;
    out = (unsigned char *)PyBytes_AS_STRING(bytes);
    for (Py_ssize_t i = 0; i < n; i += 4) {
        int pad2 = s[i + 2] == '=';
        int pad3 = s[i + 3] == '=';
        int v0, v1, v2, v3;
        unsigned triple;
        if ((pad2 || pad3) && i + 4 != n)
            goto bad;
        if (pad2 && !pad3)
            goto bad;
        v0 = b64_digit((unsigned char)s[i]);
        v1 = b64_digit((unsigned char)s[i + 1]);
        v2 = pad2 ? 0 : b64_digit((unsigned char)s[i + 2]);
        v3 = pad3 ? 0 : b64_digit((unsigned char)s[i + 3]);
        if (v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0)
            goto bad;
        triple = ((unsigned)v0 << 18) | ((unsigned)v1 << 12) |
                 ((unsigned)v2 << 6) | (unsigned)v3;
        if (o < out_len)
            out[o++] = (unsigned char)((triple >> 16) & 0xFF);
        if (!pad2 && o < out_len)
            out[o++] = (unsigned char)((triple >> 8) & 0xFF);
        if (!pad3 && o < out_len)
            out[o++] = (unsigned char)(triple & 0xFF);
    }
    if (o != out_len)
        goto bad;
    return bytes;
bad:
    Py_DECREF(bytes);
    PyErr_SetString(PyExc_ValueError, "bridge: invalid __bytes__ base64");
    return NULL;
}

static PyObject *make_tag_obj(const char *key, PyObject *value)
{
    PyObject *marker = PyDict_New();
    if (marker == NULL)
        return NULL;
    if (PyDict_SetItemString(marker, key, value) < 0) {
        Py_DECREF(marker);
        return NULL;
    }
    return marker;
}

static PyObject *make_tag(const char *key, const char *token)
{
    PyObject *text = PyUnicode_FromString(token);
    PyObject *marker;
    if (text == NULL)
        return NULL;
    marker = make_tag_obj(key, text);
    Py_DECREF(text);
    return marker;
}

/* 1 и *out (new ref) — тег; 0 — не тег; -1 — битый тег. */
static int try_decode_tag(PyObject *dict, PyObject **out)
{
    PyObject *encoded = PyDict_GetItemString(dict, "__bytes__");
    PyObject *token;
    const char *text;
    double value;
    if (encoded != NULL) {
        if (!PyUnicode_Check(encoded))
            return 0;
        *out = b64_decode(encoded);
        return *out == NULL ? -1 : 1;
    }
    token = PyDict_GetItemString(dict, "__float__");
    if (token == NULL)
        return 0;
    if (!PyUnicode_Check(token))
        return 0;
    text = PyUnicode_AsUTF8(token);
    if (text == NULL)
        return -1;
    if (strcmp(text, "inf") == 0)
        value = Py_INFINITY;
    else if (strcmp(text, "-inf") == 0)
        value = -Py_INFINITY;
    else if (strcmp(text, "nan") == 0)
        value = Py_NAN;
    else {
        PyErr_Format(PyExc_ValueError, "bridge: unknown __float__ tag %R", token);
        return -1;
    }
    *out = PyFloat_FromDouble(value);
    return *out == NULL ? -1 : 1;
}

/* --- утилиты json -------------------------------------------------------- */

static PyObject *json_dumps_obj(xt_state *st, PyObject *obj)
{
    PyObject *args = PyTuple_Pack(1, obj);
    PyObject *text;
    if (args == NULL)
        return NULL;
    text = PyObject_Call(st->json_dumps, args, st->dumps_kw);
    Py_DECREF(args);
    return text;
}

static char *json_dups_obj(xt_state *st, PyObject *obj)
{
    PyObject *text = json_dumps_obj(st, obj);
    PyObject *raw;
    char *out;
    if (text == NULL)
        return NULL;
    raw = PyUnicode_AsUTF8String(text);
    Py_DECREF(text);
    if (raw == NULL)
        return NULL;
    out = dup_cstr(PyBytes_AsString(raw), PyBytes_GET_SIZE(raw));
    Py_DECREF(raw);
    if (out == NULL)
        PyErr_NoMemory();
    return out;
}

static PyObject *json_loads_cstr(xt_state *st, const char *cstr, Py_ssize_t n)
{
    PyObject *raw = PyBytes_FromStringAndSize(cstr, n);
    PyObject *obj;
    if (raw == NULL)
        return NULL;
    obj = PyObject_CallOneArg(st->json_loads, raw);
    Py_DECREF(raw);
    return obj;
}

static const char *as_cutf8(PyObject *uni, PyObject **tmp)
{
    PyObject *raw;
    *tmp = NULL;
    if (PyBytes_Check(uni))
        return PyBytes_AsString(uni);
    raw = PyUnicode_AsUTF8String(uni);
    if (raw == NULL)
        return NULL;
    *tmp = raw;
    return PyBytes_AsString(raw);
}

/* =========================================================================
 * BridgeBackend
 * ========================================================================= */

typedef struct {
    PyObject_HEAD
    PyObject *service;
    PyObject *fields;
    PyObject *classes;
} BridgeBackendObject;

static int bb_load_manifest(xt_state *st, BridgeBackendObject *self,
                            PyObject *path_obj)
{
    PyObject *path_unref = NULL;
    const char *path;
    FILE *fh;
    long n;
    char *buf = NULL;
    PyObject *manifest = NULL;
    PyObject *classes;
    PyObject *fields;
    PyObject *known;
    int ok = 0;
    Py_ssize_t pos = 0;
    PyObject *fqcn = NULL;
    PyObject *entry = NULL;

    if (path_obj != NULL && path_obj != Py_None) {
        path_unref = PyObject_Str(path_obj);
        if (path_unref == NULL)
            return -1;
    }
    else {
        const char *env = getenv("EXTERALESS_MANIFEST");
        if (env != NULL && env[0] != '\0')
            path_unref = PyUnicode_FromString(env);
        else if (st->default_manifest != NULL)
            path_unref = PyUnicode_FromString(st->default_manifest);
        if (path_unref == NULL) {
            self->fields = PyDict_New();
            self->classes = PySet_New(NULL);
            if (self->fields == NULL || self->classes == NULL) {
                Py_XDECREF(self->fields);
                Py_XDECREF(self->classes);
                self->fields = NULL;
                self->classes = NULL;
                return -1;
            }
            return 0;
        }
    }
    path = PyUnicode_AsUTF8(path_unref);
    if (path == NULL) {
        Py_DECREF(path_unref);
        return -1;
    }

    fh = fopen(path, "rb");
    if (fh == NULL) {
        Py_DECREF(path_unref);
        self->fields = PyDict_New();
        self->classes = PySet_New(NULL);
        if (self->fields == NULL || self->classes == NULL) {
            Py_XDECREF(self->fields);
            Py_XDECREF(self->classes);
            self->fields = NULL;
            self->classes = NULL;
            return -1;
        }
        return 0;
    }
    if (fseek(fh, 0, SEEK_END) != 0) {
        fclose(fh);
        Py_DECREF(path_unref);
        PyErr_SetString(PyExc_OSError, "bridge: manifest seek failed");
        return -1;
    }
    n = ftell(fh);
    if (n < 0 || fseek(fh, 0, SEEK_SET) != 0) {
        fclose(fh);
        Py_DECREF(path_unref);
        PyErr_SetString(PyExc_OSError, "bridge: manifest size failed");
        return -1;
    }
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

    if (n > 0)
        manifest = json_loads_cstr(st, buf, (Py_ssize_t)n);
    free(buf);
    Py_DECREF(path_unref);
    if (manifest == NULL) {
        if (n == 0 && !PyErr_Occurred())
            PyErr_SetString(PyExc_ValueError, "bridge: empty manifest");
        return -1;
    }
    if (!PyDict_Check(manifest)) {
        Py_DECREF(manifest);
        return bridge_error(st, "manifest: root is not an object");
    }

    classes = PyDict_GetItemString(manifest, "classes");
    if (classes == NULL || !PyDict_Check(classes))
        classes = manifest;

    fields = PyDict_New();
    known = PySet_New(NULL);
    if (fields == NULL || known == NULL) {
        Py_XDECREF(fields);
        Py_XDECREF(known);
        Py_DECREF(manifest);
        return -1;
    }

    while (PyDict_Next(classes, &pos, &fqcn, &entry)) {
        PyObject *declared;
        PyObject *fl;
        PyObject *fset;
        if (!PyUnicode_Check(fqcn) || !PyDict_Check(entry))
            continue;
        if (PySet_Add(known, fqcn) < 0)
            goto done;
        declared = PyDict_GetItemString(entry, "declared");
        if (declared == NULL || !PyDict_Check(declared))
            continue;
        fl = PyDict_GetItemString(declared, "fields");
        if (fl == NULL || !PyList_Check(fl))
            continue;
        fset = PySet_New(fl);
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

static PyObject *marshal_value(xt_state *st, PyObject *v)
{
    if (v == Py_None || PyBool_Check(v) || PyUnicode_Check(v))
        return Py_NewRef(v);
    if (PyFloat_Check(v)) {
        double d = PyFloat_AS_DOUBLE(v);
        const char *token;
        if (!Py_IS_NAN(d) && !Py_IS_INFINITY(d))
            return Py_NewRef(v);
        token = Py_IS_NAN(d) ? "nan" : (d < 0.0 ? "-inf" : "inf");
        return make_tag("__float__", token);
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
    if (PyBytes_Check(v)) {
        PyObject *encoded = b64_encode((const unsigned char *)PyBytes_AS_STRING(v),
                                       PyBytes_GET_SIZE(v));
        PyObject *marker;
        if (encoded == NULL)
            return NULL;
        marker = make_tag_obj("__bytes__", encoded);
        Py_DECREF(encoded);
        return marker;
    }
    if (PyList_Check(v) || PyTuple_Check(v)) {
        PyObject *out = PyList_New(PySequence_Size(v));
        PyObject *iter;
        PyObject *item;
        Py_ssize_t i = 0;
        if (out == NULL)
            return NULL;
        iter = PyObject_GetIter(v);
        if (iter == NULL) {
            Py_DECREF(out);
            return NULL;
        }
        while ((item = PyIter_Next(iter)) != NULL) {
            PyObject *marshalled = marshal_value(st, item);
            Py_DECREF(item);
            if (marshalled == NULL) {
                Py_DECREF(iter);
                Py_DECREF(out);
                return NULL;
            }
            PyList_SET_ITEM(out, i, marshalled);
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
        Py_ssize_t pos = 0;
        PyObject *key = NULL;
        PyObject *val = NULL;
        if (out == NULL)
            return NULL;
        while (PyDict_Next(v, &pos, &key, &val)) {
            PyObject *k = PyUnicode_Check(key) ? Py_NewRef(key)
                                               : PyObject_Str(key);
            PyObject *marshalled;
            if (k == NULL) {
                Py_DECREF(out);
                return NULL;
            }
            marshalled = marshal_value(st, val);
            if (marshalled == NULL || PyDict_SetItem(out, k, marshalled) < 0) {
                Py_XDECREF(marshalled);
                Py_DECREF(k);
                Py_DECREF(out);
                return NULL;
            }
            Py_DECREF(k);
            Py_DECREF(marshalled);
        }
        return out;
    }
    {
        int64_t id = realm_insert(st, v);
        PyObject *fqcn;
        PyObject *marker;
        PyObject *id_obj;
        if (id == 0)
            return NULL;
        fqcn = PyObject_GetAttrString(v, "_fqcn");
        if (fqcn == NULL)
            PyErr_Clear();
        else if (!PyUnicode_Check(fqcn))
            Py_CLEAR(fqcn);
        marker = PyDict_New();
        id_obj = PyLong_FromLongLong(id);
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
}

static char *marshal_payload(xt_state *st, PyObject *args, PyObject *kwargs)
{
    PyObject *arglist;
    PyObject *kwdict;
    if (kwargs != NULL && kwargs != Py_None && !PyDict_Check(kwargs)) {
        PyErr_SetString(PyExc_TypeError, "bridge: kwargs must be a dict");
        return NULL;
    }
    arglist = PyList_New(0);
    kwdict = PyDict_New();
    if (arglist == NULL || kwdict == NULL) {
        Py_XDECREF(arglist);
        Py_XDECREF(kwdict);
        return NULL;
    }
    if (args != NULL && args != Py_None) {
        PyObject *iter = PyObject_GetIter(args);
        PyObject *item;
        if (iter == NULL)
            goto fail;
        while ((item = PyIter_Next(iter)) != NULL) {
            PyObject *marshalled = marshal_value(st, item);
            int appended;
            Py_DECREF(item);
            appended = marshalled != NULL && PyList_Append(arglist, marshalled) == 0;
            Py_XDECREF(marshalled);
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
        PyObject *key = NULL;
        PyObject *val = NULL;
        while (PyDict_Next(kwargs, &pos, &key, &val)) {
            PyObject *k = PyUnicode_Check(key) ? Py_NewRef(key)
                                               : PyObject_Str(key);
            PyObject *marshalled = marshal_value(st, val);
            int stored = k != NULL && marshalled != NULL &&
                         PyDict_SetItem(kwdict, k, marshalled) == 0;
            Py_XDECREF(k);
            Py_XDECREF(marshalled);
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
            out = json_dups_obj(st, payload);
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

static PyObject *unmarshal_walk(xt_state *st, BridgeBackendObject *backend,
                                PyObject *v);

static PyObject *unmarshal_dict(xt_state *st, BridgeBackendObject *backend,
                                PyObject *dict)
{
    PyObject *err = PyDict_GetItemString(dict, "__error__");
    PyObject *id_obj;
    if (err != NULL) {
        PyObject *msg = PyObject_Str(err);
        if (msg == NULL)
            return NULL;
        bridge_error(st, "bridge host error: %S", msg);
        Py_DECREF(msg);
        return NULL;
    }
    if (PyDict_Size(dict) == 1) {
        PyObject *decoded = NULL;
        int tag = try_decode_tag(dict, &decoded);
        if (tag < 0)
            return NULL;
        if (tag > 0)
            return decoded;
    }
    id_obj = PyDict_GetItemString(dict, "__handle__");
    if (id_obj != NULL && PyLong_Check(id_obj)) {
        long long id = PyLong_AsLongLong(id_obj);
        PyObject *existing;
        PyObject *fqcn;
        HandleRealm *realm;
        if (id == -1 && PyErr_Occurred())
            return NULL;
        realm = realm_current(st);
        if (realm == NULL)
            return NULL;
        existing = ht_resolve(realm, (int64_t)id);
        if (existing != NULL)
            return Py_NewRef(existing);
        fqcn = PyDict_GetItemString(dict, "__fqcn__");
        if (fqcn != NULL && PyUnicode_Check(fqcn) && st->JavaInstance != NULL) {
            PyObject *inst = PyObject_CallFunctionObjArgs(
                st->JavaInstance, fqcn, (PyObject *)backend, NULL);
            if (inst == NULL)
                return NULL;
            if (ht_insert_with_id(realm, inst, (int64_t)id) < 0) {
                Py_DECREF(inst);
                return NULL;
            }
            return inst;
        }
        bridge_error(st, "bridge: dangling handle %lld", id);
        return NULL;
    }
    {
        PyObject *out = PyDict_New();
        Py_ssize_t pos = 0;
        PyObject *key = NULL;
        PyObject *val = NULL;
        if (out == NULL)
            return NULL;
        while (PyDict_Next(dict, &pos, &key, &val)) {
            PyObject *marshalled = unmarshal_walk(st, backend, val);
            if (marshalled == NULL || PyDict_SetItem(out, key, marshalled) < 0) {
                Py_XDECREF(marshalled);
                Py_DECREF(out);
                return NULL;
            }
            Py_DECREF(marshalled);
        }
        return out;
    }
}

static PyObject *unmarshal_walk(xt_state *st, BridgeBackendObject *backend,
                                PyObject *v)
{
    if (PyDict_Check(v))
        return unmarshal_dict(st, backend, v);
    if (PyList_Check(v)) {
        PyObject *out = PyList_New(PyList_GET_SIZE(v));
        if (out == NULL)
            return NULL;
        for (Py_ssize_t i = 0; i < PyList_GET_SIZE(v); i++) {
            PyObject *item = unmarshal_walk(st, backend, PyList_GET_ITEM(v, i));
            if (item == NULL) {
                Py_DECREF(out);
                return NULL;
            }
            PyList_SET_ITEM(out, i, item);
        }
        return out;
    }
    if (PyTuple_Check(v)) {
        PyObject *out = PyTuple_New(PyTuple_GET_SIZE(v));
        if (out == NULL)
            return NULL;
        for (Py_ssize_t i = 0; i < PyTuple_GET_SIZE(v); i++) {
            PyObject *item = unmarshal_walk(st, backend, PyTuple_GET_ITEM(v, i));
            if (item == NULL) {
                Py_DECREF(out);
                return NULL;
            }
            PyTuple_SET_ITEM(out, i, item);
        }
        return out;
    }
    return Py_NewRef(v);
}

static PyObject *unmarshal_result(xt_state *st, BridgeBackendObject *backend,
                                  char *res)
{
    size_t n;
    PyObject *parsed;
    PyObject *out;
    if (res == NULL)
        Py_RETURN_NONE;
    n = strlen(res);
    if (n == 0) {
        free(res);
        Py_RETURN_NONE;
    }
    parsed = json_loads_cstr(st, res, (Py_ssize_t)n);
    free(res);
    if (parsed == NULL)
        return NULL;
    out = unmarshal_walk(st, backend, parsed);
    Py_DECREF(parsed);
    return out;
}

static void *bb_resolve_op(BridgeBackendObject *self, int op)
{
    PyObject *name = PyUnicode_FromFormat("%U.%s", self->service, OP_SUFFIX[op]);
    const char *text;
    void *fn;
    if (name == NULL)
        return NULL;
    text = PyUnicode_AsUTF8(name);
    fn = text != NULL ? registry_find(text) : NULL;
    Py_DECREF(name);
    if (fn == NULL) {
        xt_state *st = state_of_backend((PyObject *)self);
        bridge_error(st, "no bridge service registered for '%U.%s'",
                     self->service, OP_SUFFIX[op]);
    }
    return fn;
}

static PyObject *instance_fqcn(PyObject *instance)
{
    PyObject *fqcn = PyObject_GetAttrString(instance, "_fqcn");
    PyObject *tp;
    if (fqcn != NULL)
        return fqcn;
    PyErr_Clear();
    tp = PyObject_GetAttrString(instance, "__class__");
    if (tp == NULL)
        return NULL;
    fqcn = PyObject_GetAttrString(tp, "__name__");
    Py_DECREF(tp);
    return fqcn;
}

static int bb_class_known(BridgeBackendObject *self, PyObject *fqcn)
{
    return PySet_Contains(self->classes, fqcn);
}

static int bb_after_callback(int rc)
{
    if (PyErr_Occurred()) {
        PyErr_Clear();
        return -1;
    }
    return rc != 0 ? -2 : 0;
}

static PyObject *bb_construct(BridgeBackendObject *self,
                              PyObject *const *fast, Py_ssize_t n)
{
    xt_state *st = state_of_backend((PyObject *)self);
    PyObject *fqcn;
    PyObject *args;
    int known;
    char *payload;
    xt_construct_fn fn;
    PyObject *tmp = NULL;
    const char *fqcn_c;
    char *res = NULL;
    int bad;
    if (st == NULL)
        return NULL;
    if (n != 2) {
        PyErr_SetString(PyExc_TypeError,
                        "construct(fqcn, args) takes exactly 2 arguments");
        return NULL;
    }
    fqcn = fast[0];
    args = fast[1];
    if (!PyUnicode_Check(fqcn)) {
        PyErr_SetString(PyExc_TypeError, "construct: fqcn must be str");
        return NULL;
    }
    known = bb_class_known(self, fqcn);
    if (known < 0)
        return NULL;
    if (!known) {
        bridge_error(st, "no class %R", fqcn);
        return NULL;
    }
    payload = marshal_payload(st, args, NULL);
    if (payload == NULL)
        return NULL;
    fn = (xt_construct_fn)bb_resolve_op(self, OP_CONSTRUCT);
    fqcn_c = fn != NULL ? as_cutf8(fqcn, &tmp) : NULL;
    if (fn == NULL || fqcn_c == NULL) {
        free(payload);
        Py_XDECREF(tmp);
        return NULL;
    }
    res = NULL;
    bad = 0;
    {
        int rc = fn(fqcn_c, payload, &res);
        free(payload);
        Py_XDECREF(tmp);
        bad = bb_after_callback(rc);
        if (bad == -1) {
            free(res);
            bridge_error(st, "bridge service '%U.construct' left a pending exception",
                         self->service);
            return NULL;
        }
        if (bad == -2) {
            free(res);
            bridge_error(st, "bridge service '%U.construct' failed (rc=%d)",
                         self->service, rc);
            return NULL;
        }
    }
    return unmarshal_result(st, self, res);
}

static PyObject *bb_call(BridgeBackendObject *self,
                         PyObject *const *fast, Py_ssize_t n,
                         PyObject *kwnames)
{
    xt_state *st = state_of_backend((PyObject *)self);
    PyObject *fqcn;
    PyObject *member;
    PyObject *args;
    PyObject *kwargs;
    int known;
    char *payload;
    xt_call_fn fn;
    PyObject *t1 = NULL;
    PyObject *t2 = NULL;
    const char *fqcn_c;
    const char *member_c;
    char *res = NULL;
    int rc;
    int bad;
    if (st == NULL)
        return NULL;
    if (kwnames != NULL || n != 4) {
        PyErr_SetString(PyExc_TypeError,
                        "call(fqcn, member, args, kwargs) takes 4 positional "
                        "arguments");
        return NULL;
    }
    fqcn = fast[0];
    member = fast[1];
    args = fast[2];
    kwargs = fast[3];
    if (!PyUnicode_Check(fqcn) || !PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "call: fqcn/member must be str");
        return NULL;
    }
    known = bb_class_known(self, fqcn);
    if (known < 0)
        return NULL;
    if (!known) {
        bridge_error(st, "no class %R", fqcn);
        return NULL;
    }
    payload = marshal_payload(st, args, kwargs);
    if (payload == NULL)
        return NULL;
    fn = (xt_call_fn)bb_resolve_op(self, OP_CALL);
    fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        free(payload);
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    rc = fn(fqcn_c, member_c, payload, &res);
    free(payload);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    bad = bb_after_callback(rc);
    if (bad == -1) {
        free(res);
        bridge_error(st, "bridge service '%U.call' left a pending exception",
                     self->service);
        return NULL;
    }
    if (bad == -2) {
        free(res);
        bridge_error(st, "bridge service '%U.call' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    return unmarshal_result(st, self, res);
}

static PyObject *bb_call_instance(BridgeBackendObject *self,
                                  PyObject *const *fast, Py_ssize_t n,
                                  PyObject *kwnames)
{
    xt_state *st = state_of_backend((PyObject *)self);
    PyObject *instance;
    PyObject *member;
    PyObject *args;
    PyObject *kwargs;
    int64_t handle;
    PyObject *fqcn;
    char *payload;
    xt_call_instance_fn fn;
    PyObject *t1 = NULL;
    PyObject *t2 = NULL;
    const char *fqcn_c;
    const char *member_c;
    char *res = NULL;
    int rc;
    int bad;
    if (st == NULL)
        return NULL;
    if (kwnames != NULL || n != 4) {
        PyErr_SetString(PyExc_TypeError,
                        "call_instance(instance, member, args, kwargs) takes "
                        "4 positional arguments");
        return NULL;
    }
    instance = fast[0];
    member = fast[1];
    args = fast[2];
    kwargs = fast[3];
    if (!PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "call_instance: member must be str");
        return NULL;
    }
    handle = realm_insert(st, instance);
    if (handle == 0)
        return NULL;
    fqcn = instance_fqcn(instance);
    if (fqcn == NULL)
        return NULL;
    payload = marshal_payload(st, args, kwargs);
    if (payload == NULL) {
        Py_DECREF(fqcn);
        return NULL;
    }
    fn = (xt_call_instance_fn)bb_resolve_op(self, OP_CALL_INSTANCE);
    fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        free(payload);
        Py_DECREF(fqcn);
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    rc = fn(handle, fqcn_c, member_c, payload, &res);
    free(payload);
    Py_DECREF(fqcn);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    bad = bb_after_callback(rc);
    if (bad == -1) {
        free(res);
        bridge_error(st, "bridge service '%U.call_instance' left a pending "
                     "exception", self->service);
        return NULL;
    }
    if (bad == -2) {
        free(res);
        bridge_error(st, "bridge service '%U.call_instance' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    return unmarshal_result(st, self, res);
}

static PyObject *bb_get(BridgeBackendObject *self,
                        PyObject *const *fast, Py_ssize_t n)
{
    xt_state *st = state_of_backend((PyObject *)self);
    PyObject *fqcn;
    PyObject *member;
    xt_get_fn fn;
    PyObject *t1 = NULL;
    PyObject *t2 = NULL;
    const char *fqcn_c;
    const char *member_c;
    char *res = NULL;
    int rc;
    int bad;
    if (st == NULL)
        return NULL;
    if (n != 2) {
        PyErr_SetString(PyExc_TypeError,
                        "get(fqcn, member) takes 2 arguments");
        return NULL;
    }
    fqcn = fast[0];
    member = fast[1];
    if (!PyUnicode_Check(fqcn) || !PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "get: fqcn/member must be str");
        return NULL;
    }
    fn = (xt_get_fn)bb_resolve_op(self, OP_GET);
    fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    rc = fn(fqcn_c, member_c, &res);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    bad = bb_after_callback(rc);
    if (bad == -1) {
        free(res);
        bridge_error(st, "bridge service '%U.get' left a pending exception",
                     self->service);
        return NULL;
    }
    if (bad == -2) {
        free(res);
        bridge_error(st, "bridge service '%U.get' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    return unmarshal_result(st, self, res);
}

static PyObject *bb_get_instance(BridgeBackendObject *self,
                                 PyObject *const *fast, Py_ssize_t n)
{
    xt_state *st = state_of_backend((PyObject *)self);
    PyObject *instance;
    PyObject *member;
    int64_t handle;
    PyObject *fqcn;
    xt_get_instance_fn fn;
    PyObject *t1 = NULL;
    PyObject *t2 = NULL;
    const char *fqcn_c;
    const char *member_c;
    char *res = NULL;
    int rc;
    int bad;
    if (st == NULL)
        return NULL;
    if (n != 2) {
        PyErr_SetString(PyExc_TypeError,
                        "get_instance(instance, member) takes 2 arguments");
        return NULL;
    }
    instance = fast[0];
    member = fast[1];
    if (!PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "get_instance: member must be str");
        return NULL;
    }
    handle = realm_insert(st, instance);
    if (handle == 0)
        return NULL;
    fqcn = instance_fqcn(instance);
    if (fqcn == NULL)
        return NULL;
    fn = (xt_get_instance_fn)bb_resolve_op(self, OP_GET_INSTANCE);
    fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        Py_DECREF(fqcn);
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    rc = fn(handle, fqcn_c, member_c, &res);
    Py_DECREF(fqcn);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    bad = bb_after_callback(rc);
    if (bad == -1) {
        free(res);
        bridge_error(st, "bridge service '%U.get_instance' left a pending "
                     "exception", self->service);
        return NULL;
    }
    if (bad == -2) {
        free(res);
        bridge_error(st, "bridge service '%U.get_instance' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    return unmarshal_result(st, self, res);
}

static PyObject *bb_set(BridgeBackendObject *self,
                        PyObject *const *fast, Py_ssize_t n)
{
    xt_state *st = state_of_backend((PyObject *)self);
    PyObject *fqcn;
    PyObject *member;
    PyObject *value;
    PyObject *marshalled;
    char *payload;
    xt_set_fn fn;
    PyObject *t1 = NULL;
    PyObject *t2 = NULL;
    const char *fqcn_c;
    const char *member_c;
    int rc;
    int bad;
    if (st == NULL)
        return NULL;
    if (n != 3) {
        PyErr_SetString(PyExc_TypeError,
                        "set(fqcn, member, value) takes 3 arguments");
        return NULL;
    }
    fqcn = fast[0];
    member = fast[1];
    value = fast[2];
    if (!PyUnicode_Check(fqcn) || !PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "set: fqcn/member must be str");
        return NULL;
    }
    marshalled = marshal_value(st, value);
    if (marshalled == NULL)
        return NULL;
    payload = json_dups_obj(st, marshalled);
    Py_DECREF(marshalled);
    if (payload == NULL)
        return NULL;
    fn = (xt_set_fn)bb_resolve_op(self, OP_SET);
    fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        free(payload);
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    rc = fn(fqcn_c, member_c, payload);
    free(payload);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    bad = bb_after_callback(rc);
    if (bad == -1) {
        bridge_error(st, "bridge service '%U.set' left a pending exception",
                     self->service);
        return NULL;
    }
    if (bad == -2) {
        bridge_error(st, "bridge service '%U.set' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bb_set_instance(BridgeBackendObject *self,
                                 PyObject *const *fast, Py_ssize_t n)
{
    xt_state *st = state_of_backend((PyObject *)self);
    PyObject *instance;
    PyObject *member;
    PyObject *value;
    int64_t handle;
    PyObject *fqcn;
    PyObject *marshalled;
    char *payload;
    xt_set_instance_fn fn;
    PyObject *t1 = NULL;
    PyObject *t2 = NULL;
    const char *fqcn_c;
    const char *member_c;
    int rc;
    int bad;
    if (st == NULL)
        return NULL;
    if (n != 3) {
        PyErr_SetString(PyExc_TypeError,
                        "set_instance(instance, member, value) takes 3 "
                        "arguments");
        return NULL;
    }
    instance = fast[0];
    member = fast[1];
    value = fast[2];
    if (!PyUnicode_Check(member)) {
        PyErr_SetString(PyExc_TypeError, "set_instance: member must be str");
        return NULL;
    }
    handle = realm_insert(st, instance);
    if (handle == 0)
        return NULL;
    fqcn = instance_fqcn(instance);
    if (fqcn == NULL)
        return NULL;
    marshalled = marshal_value(st, value);
    if (marshalled == NULL) {
        Py_DECREF(fqcn);
        return NULL;
    }
    payload = json_dups_obj(st, marshalled);
    Py_DECREF(marshalled);
    if (payload == NULL) {
        Py_DECREF(fqcn);
        return NULL;
    }
    fn = (xt_set_instance_fn)bb_resolve_op(self, OP_SET_INSTANCE);
    fqcn_c = fn != NULL ? as_cutf8(fqcn, &t1) : NULL;
    member_c = fn != NULL ? as_cutf8(member, &t2) : NULL;
    if (fn == NULL || fqcn_c == NULL || member_c == NULL) {
        free(payload);
        Py_DECREF(fqcn);
        Py_XDECREF(t1);
        Py_XDECREF(t2);
        return NULL;
    }
    rc = fn(handle, fqcn_c, member_c, payload);
    free(payload);
    Py_DECREF(fqcn);
    Py_XDECREF(t1);
    Py_XDECREF(t2);
    bad = bb_after_callback(rc);
    if (bad == -1) {
        bridge_error(st, "bridge service '%U.set_instance' left a pending "
                     "exception", self->service);
        return NULL;
    }
    if (bad == -2) {
        bridge_error(st, "bridge service '%U.set_instance' failed (rc=%d)",
                     self->service, rc);
        return NULL;
    }
    Py_RETURN_NONE;
}

static PyObject *bb_member_kind(BridgeBackendObject *self,
                                PyObject *const *fast, Py_ssize_t n)
{
    PyObject *fqcn;
    PyObject *member;
    PyObject *fset;
    int contains;
    if (n != 2) {
        PyErr_SetString(PyExc_TypeError,
                        "member_kind(fqcn, member) takes 2 arguments");
        return NULL;
    }
    fqcn = fast[0];
    member = fast[1];
    fset = PyDict_GetItemWithError(self->fields, fqcn);
    if (fset == NULL) {
        if (PyErr_Occurred())
            return NULL;
        return PyUnicode_FromString("unknown");
    }
    contains = PySequence_Contains(fset, member);
    if (contains < 0)
        return NULL;
    return PyUnicode_FromString(contains ? "field" : "method");
}

static PyObject *bb_class_exists(BridgeBackendObject *self,
                                 PyObject *const *fast, Py_ssize_t n)
{
    int known;
    if (n != 1) {
        PyErr_SetString(PyExc_TypeError,
                        "class_exists(fqcn) takes 1 argument");
        return NULL;
    }
    if (!PyUnicode_Check(fast[0])) {
        PyErr_SetString(PyExc_TypeError, "class_exists: fqcn must be str");
        return NULL;
    }
    known = bb_class_known(self, fast[0]);
    if (known < 0)
        return NULL;
    return PyBool_FromLong(known);
}

static int bb_init(BridgeBackendObject *self, PyObject *args, PyObject *kwds)
{
    static char *kwlist[] = {"service", "manifest_path", NULL};
    PyObject *service = NULL;
    PyObject *manifest_path = NULL;
    PyObject *svc;
    xt_state *st = state_of_backend((PyObject *)self);
    if (st == NULL)
        return -1;
    if (!PyArg_ParseTupleAndKeywords(args, kwds, "|OO", kwlist,
                                     &service, &manifest_path))
        return -1;
    if (service == NULL || service == Py_None)
        svc = PyUnicode_FromString("java");
    else
        svc = PyObject_Str(service);
    if (svc == NULL)
        return -1;
    Py_XSETREF(self->service, svc);
    Py_CLEAR(self->fields);
    Py_CLEAR(self->classes);
    if (bb_load_manifest(st, self, manifest_path) < 0)
        return -1;
    return 0;
}

static void bb_dealloc(PyObject *self)
{
    BridgeBackendObject *bb = (BridgeBackendObject *)self;
    PyTypeObject *tp = Py_TYPE(self);
    Py_CLEAR(bb->service);
    Py_CLEAR(bb->fields);
    Py_CLEAR(bb->classes);
    tp->tp_free(self);
    Py_DECREF(tp);
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

static char bb_doc[] =
    "C-реализация Backend: вызовы уходят в реестр сервисов "
    "xt_register_service. Протокол — см. python/virtualjava/backend.py";

static PyType_Slot bb_slots[] = {
    {Py_tp_doc, bb_doc},
    {Py_tp_new, PyType_GenericNew},
    {Py_tp_init, bb_init},
    {Py_tp_dealloc, bb_dealloc},
    {Py_tp_methods, bb_methods},
    {0, NULL}
};

static PyType_Spec bb_spec = {
    .name = "_exteraless_bridge.BridgeBackend",
    .basicsize = (int)sizeof(BridgeBackendObject),
    .itemsize = 0,
    .flags = Py_TPFLAGS_DEFAULT | Py_TPFLAGS_BASETYPE,
    .slots = bb_slots,
};

/* =========================================================================
 * встроенный mock-сервис (Windows/тесты): зеркалит MockBackend
 * ========================================================================= */

static int mock_note(xt_state *st, const char *op, const char *fqcn,
                     const char *member, int64_t handle, PyObject *args,
                     PyObject *kwargs)
{
    PyObject *rec;
    int ok = 1;
    PyObject *v;
    int appended;
    if (st->mock_log == NULL ||
        PyList_GET_SIZE(st->mock_log) >= XT_MOCK_LOG_CAP) {
        Py_XDECREF(args);
        Py_XDECREF(kwargs);
        return 0;
    }
    rec = PyDict_New();
    if (rec == NULL) {
        Py_XDECREF(args);
        Py_XDECREF(kwargs);
        return -1;
    }
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
    appended = PyList_Append(st->mock_log, rec) == 0;
    Py_DECREF(rec);
    return appended ? 0 : -1;
}

static void mock_parse_payload(xt_state *st, const char *json_args,
                               PyObject **out_args, PyObject **out_kwargs)
{
    PyObject *obj;
    *out_args = NULL;
    *out_kwargs = NULL;
    if (json_args == NULL)
        return;
    obj = json_loads_cstr(st, json_args, (Py_ssize_t)strlen(json_args));
    if (obj == NULL) {
        PyErr_Clear();
        return;
    }
    if (PyDict_Check(obj)) {
        PyObject *args = PyDict_GetItemString(obj, "args");
        PyObject *kwargs = PyDict_GetItemString(obj, "kwargs");
        if (args != NULL)
            *out_args = Py_NewRef(args);
        if (kwargs != NULL)
            *out_kwargs = Py_NewRef(kwargs);
    }
    Py_DECREF(obj);
}

static int mock_fail(char **json_result)
{
    PyErr_Clear();
    if (json_result != NULL)
        *json_result = NULL;
    return 1;
}

static int mock_require(xt_state **out)
{
    xt_state *st = xt_state_get();
    if (st == NULL) {
        PyErr_Clear();
        return -1;
    }
    *out = st;
    return 0;
}

static int mock_construct(const char *fqcn, const char *json_args,
                          char **json_result)
{
    xt_state *st;
    PyObject *args = NULL;
    PyObject *kwargs = NULL;
    int64_t handle;
    PyObject *res;
    PyObject *hid;
    PyObject *fq;
    int ok;
    if (mock_require(&st) < 0)
        return mock_fail(json_result);
    mock_parse_payload(st, json_args, &args, &kwargs);
    handle = st->mock_next_handle--;
    if (mock_note(st, "construct", fqcn, "<init>", handle, args, kwargs) < 0)
        return mock_fail(json_result);
    res = PyDict_New();
    hid = PyLong_FromLongLong(handle);
    fq = PyUnicode_FromString(fqcn);
    ok = res != NULL && hid != NULL && fq != NULL &&
         PyDict_SetItemString(res, "__handle__", hid) == 0 &&
         PyDict_SetItemString(res, "__fqcn__", fq) == 0;
    Py_XDECREF(hid);
    Py_XDECREF(fq);
    if (!ok) {
        Py_XDECREF(res);
        return mock_fail(json_result);
    }
    *json_result = json_dups_obj(st, res);
    Py_DECREF(res);
    if (*json_result == NULL)
        return mock_fail(json_result);
    return 0;
}

static int mock_echo_first(xt_state *st, const char *json_args,
                           char **json_result)
{
    PyObject *obj = json_loads_cstr(st, json_args, (Py_ssize_t)strlen(json_args));
    PyObject *val = NULL;
    char *out;
    if (obj == NULL)
        return mock_fail(json_result);
    if (PyDict_Check(obj)) {
        PyObject *args = PyDict_GetItemString(obj, "args");
        if (args != NULL && PyList_Check(args) && PyList_GET_SIZE(args) > 0)
            val = Py_NewRef(PyList_GET_ITEM(args, 0));
    }
    if (val == NULL)
        val = Py_NewRef(Py_None);
    out = json_dups_obj(st, val);
    Py_DECREF(val);
    Py_DECREF(obj);
    if (out == NULL)
        return mock_fail(json_result);
    *json_result = out;
    return 0;
}

static int mock_str_result(xt_state *st, const char *prefix, const char *fqcn,
                           const char *member, char **json_result)
{
    PyObject *text = PyUnicode_FromFormat("%s%s#%s", prefix, fqcn, member);
    if (text == NULL)
        return mock_fail(json_result);
    *json_result = json_dups_obj(st, text);
    Py_DECREF(text);
    if (*json_result == NULL)
        return mock_fail(json_result);
    return 0;
}

static int mock_call(const char *fqcn, const char *member,
                     const char *json_args, char **json_result)
{
    xt_state *st;
    PyObject *args = NULL;
    PyObject *kwargs = NULL;
    if (mock_require(&st) < 0)
        return mock_fail(json_result);
    if (strcmp(member, "echoFirst") == 0)
        return mock_echo_first(st, json_args, json_result);
    mock_parse_payload(st, json_args, &args, &kwargs);
    if (mock_note(st, "call", fqcn, member, 0, args, kwargs) < 0)
        return mock_fail(json_result);
    return mock_str_result(st, "result:", fqcn, member, json_result);
}

static int mock_call_instance(int64_t handle, const char *fqcn,
                              const char *member, const char *json_args,
                              char **json_result)
{
    xt_state *st;
    PyObject *args = NULL;
    PyObject *kwargs = NULL;
    if (mock_require(&st) < 0)
        return mock_fail(json_result);
    if (strcmp(member, "echoFirst") == 0)
        return mock_echo_first(st, json_args, json_result);
    mock_parse_payload(st, json_args, &args, &kwargs);
    if (mock_note(st, "call_instance", fqcn, member, handle, args, kwargs) < 0)
        return mock_fail(json_result);
    return mock_str_result(st, "result:", fqcn, member, json_result);
}

static int mock_get(const char *fqcn, const char *member, char **json_result)
{
    xt_state *st;
    if (mock_require(&st) < 0)
        return mock_fail(json_result);
    if (mock_note(st, "get", fqcn, member, 0, NULL, NULL) < 0)
        return mock_fail(json_result);
    return mock_str_result(st, "field:", fqcn, member, json_result);
}

static int mock_get_instance(int64_t handle, const char *fqcn,
                             const char *member, char **json_result)
{
    xt_state *st;
    if (mock_require(&st) < 0)
        return mock_fail(json_result);
    if (mock_note(st, "get_instance", fqcn, member, handle, NULL, NULL) < 0)
        return mock_fail(json_result);
    return mock_str_result(st, "field:", fqcn, member, json_result);
}

static int mock_set(const char *fqcn, const char *member, const char *json_value)
{
    xt_state *st;
    PyObject *value = NULL;
    if (mock_require(&st) < 0) {
        PyErr_Clear();
        return 1;
    }
    if (json_value != NULL)
        value = json_loads_cstr(st, json_value, (Py_ssize_t)strlen(json_value));
    if (value == NULL)
        PyErr_Clear();
    if (mock_note(st, "set", fqcn, member, 0, value, NULL) < 0) {
        PyErr_Clear();
        return 1;
    }
    return 0;
}

static int mock_set_instance(int64_t handle, const char *fqcn,
                             const char *member, const char *json_value)
{
    xt_state *st;
    PyObject *value = NULL;
    if (mock_require(&st) < 0) {
        PyErr_Clear();
        return 1;
    }
    if (json_value != NULL)
        value = json_loads_cstr(st, json_value, (Py_ssize_t)strlen(json_value));
    if (value == NULL)
        PyErr_Clear();
    if (mock_note(st, "set_instance", fqcn, member, handle, value, NULL) < 0) {
        PyErr_Clear();
        return 1;
    }
    PyErr_Clear();
    return 0;
}

/* Хост (Swift) освобождает handle текущего интерпретатора и активной таблицы.
 * GIL берётся здесь: ctypes и чужой поток приходят без него. См. шапку. */
int xt_host_release_handle(int64_t handle)
{
    PyGILState_STATE gs = PyGILState_Ensure();
    xt_state *st;
    HandleRealm *realm;
    int rc;
    st = xt_state_get();
    if (st == NULL) {
        PyGILState_Release(gs);
        return -1;
    }
    realm = realm_current(st);
    if (realm == NULL) {
        PyGILState_Release(gs);
        return -1;
    }
    rc = ht_remove(realm, handle);
    PyGILState_Release(gs);
    return rc;
}

/* =========================================================================
 * Python-видимое API модуля
 * ========================================================================= */

static PyObject *py_xt_register_service(PyObject *self, PyObject *args)
{
    const char *name;
    PyObject *ptr;
    void *fn;
    (void)self;
    if (!PyArg_ParseTuple(args, "sO", &name, &ptr))
        return NULL;
    fn = PyLong_AsVoidPtr(ptr);
    if (fn == NULL) {
        if (PyErr_Occurred())
            return NULL;
        PyErr_SetString(PyExc_ValueError, "xt_register_service: null pointer");
        return NULL;
    }
    if (registry_upsert(name, fn) < 0)
        return NULL;
    Py_RETURN_NONE;
}

static PyObject *py_xt_unregister_service(PyObject *self, PyObject *args)
{
    const char *name;
    (void)self;
    if (!PyArg_ParseTuple(args, "s", &name))
        return NULL;
    return PyBool_FromLong(registry_remove(name));
}

static PyObject *py_xt_service_ptr(PyObject *self, PyObject *args)
{
    const char *name;
    (void)self;
    if (!PyArg_ParseTuple(args, "s", &name))
        return NULL;
    return PyLong_FromVoidPtr(registry_find(name));
}

static PyObject *py_xt_install_mock_service(PyObject *self, PyObject *args,
                                            PyObject *kwds)
{
    static char *kwlist[] = {"prefix", NULL};
    const char *prefix = "java";
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
    (void)self;
    if (!PyArg_ParseTupleAndKeywords(args, kwds, "|s", kwlist, &prefix))
        return NULL;
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
    void *fn = NULL;
    (void)self;
    if (!PyArg_ParseTuple(args, "s", &op))
        return NULL;
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
    else if (strcmp(op, "release_handle") == 0)
        fn = (void *)xt_host_release_handle;
    else {
        PyErr_Format(PyExc_ValueError, "unknown op '%s'", op);
        return NULL;
    }
    return PyLong_FromVoidPtr(fn);
}

static PyObject *py_xt_mock_log(PyObject *self, PyObject *noargs)
{
    xt_state *st = state_from_module(self);
    (void)noargs;
    if (st == NULL || st->mock_log == NULL)
        return NULL;
    return PyList_GetSlice(st->mock_log, 0, PyList_GET_SIZE(st->mock_log));
}

static PyObject *py_xt_mock_log_clear(PyObject *self, PyObject *noargs)
{
    xt_state *st = state_from_module(self);
    (void)noargs;
    if (st == NULL || st->mock_log == NULL)
        return NULL;
    if (PyList_SetSlice(st->mock_log, 0, PyList_GET_SIZE(st->mock_log), NULL) < 0)
        return NULL;
    Py_RETURN_NONE;
}

static PyObject *py_xt_register_handle(PyObject *self, PyObject *obj)
{
    xt_state *st = state_from_module(self);
    int64_t id;
    if (st == NULL)
        return NULL;
    id = realm_insert(st, obj);
    if (id == 0)
        return NULL;
    return PyLong_FromLongLong(id);
}

static PyObject *py_xt_resolve_handle(PyObject *self, PyObject *arg)
{
    xt_state *st = state_from_module(self);
    long long id;
    PyObject *obj;
    if (st == NULL)
        return NULL;
    id = PyLong_AsLongLong(arg);
    if (id == -1 && PyErr_Occurred())
        return NULL;
    obj = realm_resolve(st, (int64_t)id);
    if (obj == NULL) {
        if (PyErr_Occurred())
            return NULL;
        Py_RETURN_NONE;
    }
    return Py_NewRef(obj);
}

static PyObject *py_xt_release_handle(PyObject *self, PyObject *arg)
{
    xt_state *st = state_from_module(self);
    HandleRealm *realm;
    long long id;
    if (st == NULL)
        return NULL;
    id = PyLong_AsLongLong(arg);
    if (id == -1 && PyErr_Occurred())
        return NULL;
    realm = realm_current(st);
    if (realm == NULL)
        return NULL;
    return PyBool_FromLong(ht_remove(realm, (int64_t)id));
}

static PyObject *py_xt_handle_count(PyObject *self, PyObject *noargs)
{
    xt_state *st = state_from_module(self);
    HandleRealm *realm;
    (void)noargs;
    if (st == NULL)
        return NULL;
    realm = realm_current(st);
    if (realm == NULL)
        return NULL;
    return PyLong_FromSize_t(realm->handle_used);
}

static PyObject *py_xt_clear_handles(PyObject *self, PyObject *noargs)
{
    xt_state *st = state_from_module(self);
    HandleRealm *realm;
    (void)noargs;
    if (st == NULL)
        return NULL;
    realm = realm_current(st);
    if (realm == NULL)
        return NULL;
    realm_drop_entries(realm);
    Py_RETURN_NONE;
}

static PyObject *py_xt_set_interpreter_id(PyObject *self, PyObject *arg)
{
    xt_state *st = state_from_module(self);
    long long key;
    long long prev;
    if (st == NULL)
        return NULL;
    key = PyLong_AsLongLong(arg);
    if (key == -1 && PyErr_Occurred())
        return NULL;
    if (realm_create(st, key) == NULL)
        return NULL;
    prev = st->active_key;
    st->active_key = key;
    return PyLong_FromLongLong(prev);
}

static PyObject *py_xt_bind(PyObject *self, PyObject *args)
{
    xt_state *st = state_from_module(self);
    PyObject *instance_cls;
    PyObject *error_cls;
    if (st == NULL)
        return NULL;
    if (!PyArg_ParseTuple(args, "OO", &instance_cls, &error_cls))
        return NULL;
    if (!PyType_Check(instance_cls) || !PyType_Check(error_cls)) {
        PyErr_SetString(PyExc_TypeError, "xt_bind expects two classes");
        return NULL;
    }
    Py_XSETREF(st->JavaInstance, Py_NewRef(instance_cls));
    Py_XSETREF(st->JavaMemberError, Py_NewRef(error_cls));
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
     "xt_builtin_ptr(op) -> int — адрес встроенной mock-функции или "
     "'release_handle' (xt_host_release_handle) для Swift."},
    {"xt_mock_log", py_xt_mock_log, METH_NOARGS,
     "xt_mock_log() -> list[dict] — журнал вызовов встроенного mock-сервиса"},
    {"xt_mock_log_clear", py_xt_mock_log_clear, METH_NOARGS,
     "xt_mock_log_clear() — очистить журнал mock-сервиса"},
    {"xt_register_handle", py_xt_register_handle, METH_O,
     "xt_register_handle(obj) -> int64 id (повторный вызов — тот же id)"},
    {"xt_resolve_handle", py_xt_resolve_handle, METH_O,
     "xt_resolve_handle(id) -> obj | None (тот же объект по тому же id)"},
    {"xt_release_handle", py_xt_release_handle, METH_O,
     "xt_release_handle(id) -> bool — убрать объект из handle-таблицы "
     "текущего интерпретатора"},
    {"xt_handle_count", py_xt_handle_count, METH_NOARGS,
     "xt_handle_count() -> int"},
    {"xt_clear_handles", py_xt_clear_handles, METH_NOARGS,
     "xt_clear_handles() — сброс активной handle-таблицы (тесты)"},
    {"xt_set_interpreter_id", py_xt_set_interpreter_id, METH_O,
     "xt_set_interpreter_id(id) -> previous. Отдельная handle-таблица внутри "
     "этого интерпретатора. По умолчанию id = PyInterpreterState_GetID(). "
     "Таблицы разных id и разных интерпретаторов не пересекаются."},
    {"xt_bind", py_xt_bind, METH_VARARGS,
     "xt_bind(JavaInstance, JavaMemberError) — классы virtualjava; "
     "python.bridge вызывает автоматически при импорте пакета"},
    {NULL, NULL, 0, NULL}
};

/* =========================================================================
 * инициализация модуля (multi-phase init, per-interpreter state)
 * ========================================================================= */

static int compute_default_manifest(xt_state *st, PyObject *module)
{
    PyObject *file = PyObject_GetAttrString(module, "__file__");
    const char *path;
    size_t len;
    char *buf;
    if (file == NULL) {
        PyErr_Clear();
        return 0;
    }
    path = PyUnicode_AsUTF8(file);
    if (path == NULL) {
        Py_DECREF(file);
        PyErr_Clear();
        return 0;
    }
    len = strlen(path);
    buf = (char *)malloc(len + 64);
    if (buf == NULL) {
        Py_DECREF(file);
        return 0;
    }
    memcpy(buf, path, len + 1);
    for (int i = 0; i < 3; i++) {
        char *sep = buf + strlen(buf);
        while (sep > buf && sep[-1] != '/' && sep[-1] != '\\')
            sep--;
        if (sep > buf)
            sep[-1] = '\0';
    }
    strcat(buf, "/build/compat/manifest.json");
    free(st->default_manifest);
    st->default_manifest = buf;
    Py_DECREF(file);
    return 0;
}

static int module_traverse(PyObject *module, visitproc visit, void *arg)
{
    xt_state *st = (xt_state *)PyModule_GetState(module);
    if (st == NULL)
        return 0;
    Py_VISIT(st->JavaInstance);
    Py_VISIT(st->JavaMemberError);
    Py_VISIT(st->json_dumps);
    Py_VISIT(st->json_loads);
    Py_VISIT(st->dumps_kw);
    Py_VISIT(st->mock_log);
    for (int i = 0; i < XT_MAX_REALMS; i++) {
        HandleRealm *realm = &st->realms[i];
        if (!realm->in_use || realm->handles == NULL)
            continue;
        for (size_t slot = 0; slot < realm->handle_cap; slot++)
            Py_VISIT(realm->handles[slot].obj);
    }
    return 0;
}

static void state_release_objects(xt_state *st)
{
    if (st->anchor != NULL) {
        st->anchor->state = NULL;
        st->anchor = NULL;
    }
    for (int i = 0; i < XT_MAX_REALMS; i++) {
        if (!st->realms[i].in_use)
            continue;
        realm_drop_entries(&st->realms[i]);
        st->realms[i].in_use = 0;
    }
    Py_CLEAR(st->JavaInstance);
    Py_CLEAR(st->JavaMemberError);
    Py_CLEAR(st->json_dumps);
    Py_CLEAR(st->json_loads);
    Py_CLEAR(st->dumps_kw);
    Py_CLEAR(st->mock_log);
    free(st->default_manifest);
    st->default_manifest = NULL;
}

static int module_clear(PyObject *module)
{
    xt_state *st = (xt_state *)PyModule_GetState(module);
    if (st == NULL)
        return 0;
    state_release_objects(st);
    return 0;
}

static void module_free(void *module)
{
    module_clear((PyObject *)module);
}

static int module_exec(PyObject *module)
{
    xt_state *st = (xt_state *)PyModule_GetState(module);
    PyObject *json_mod;
    PyInterpreterState *interp;
    int64_t interp_id;
    PyObject *type;
    if (st == NULL)
        return -1;
    json_mod = PyImport_ImportModule("json");
    if (json_mod == NULL)
        return -1;
    st->json_dumps = PyObject_GetAttrString(json_mod, "dumps");
    st->json_loads = PyObject_GetAttrString(json_mod, "loads");
    Py_DECREF(json_mod);
    if (st->json_dumps == NULL || st->json_loads == NULL)
        return -1;

    st->dumps_kw = PyDict_New();
    if (st->dumps_kw == NULL ||
        PyDict_SetItemString(st->dumps_kw, "ensure_ascii", Py_False) < 0 ||
        PyDict_SetItemString(st->dumps_kw, "allow_nan", Py_False) < 0)
        return -1;

    st->mock_log = PyList_New(0);
    if (st->mock_log == NULL)
        return -1;
    st->mock_next_handle = -1;

    if (compute_default_manifest(st, module) < 0)
        return -1;

    interp = PyInterpreterState_Get();
    if (interp == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "bridge: no current interpreter");
        return -1;
    }
    interp_id = PyInterpreterState_GetID(interp);
    if (interp_id < 0 && PyErr_Occurred())
        return -1;
    st->active_key = interp_id;
    if (realm_create(st, interp_id) == NULL)
        return -1;
    if (xt_anchor_install(module, st) < 0)
        return -1;

    type = PyType_FromModuleAndSpec(module, &bb_spec, NULL);
    if (type == NULL)
        return -1;
    if (PyModule_AddObjectRef(module, "BridgeBackend", type) < 0) {
        Py_DECREF(type);
        return -1;
    }
    Py_DECREF(type);
    if (PyModule_AddStringConstant(module, "__version__", "0.1.0") < 0)
        return -1;
    return 0;
}

static PyModuleDef_Slot module_slots[] = {
    {Py_mod_exec, module_exec},
#if PY_VERSION_HEX >= 0x030D0000
    {Py_mod_multiple_interpreters, Py_MOD_PER_INTERPRETER_GIL_SUPPORTED},
    {Py_mod_gil, Py_MOD_GIL_USED},
#endif
    {0, NULL}
};

static PyModuleDef module_def = {
    PyModuleDef_HEAD_INIT,
    .m_name = "_exteraless_bridge",
    .m_doc = "C-мост virtual-java: BridgeBackend + реестр сервисов "
             "xt_register_service + handle-таблица на интерпретатор. "
             "Контракт Swift и теги __bytes__/__float__ — в комментарии "
             "_exteraless_bridge.c.",
    .m_size = sizeof(xt_state),
    .m_methods = module_methods,
    .m_slots = module_slots,
    .m_traverse = module_traverse,
    .m_clear = module_clear,
    .m_free = module_free,
};

PyMODINIT_FUNC PyInit__exteraless_bridge(void)
{
    return PyModuleDef_Init(&module_def);
}
