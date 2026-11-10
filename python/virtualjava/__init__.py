"""Virtual-Java: слой совместимости плагинов для iOS-порта exteraless.

Заменяет Chaquopy: `import com.exteragram.messenger.X` и обращения к
членам резолвятся в прокси-объекты, а вызовы маршрутизируются в бэкенд
(C-мост `_exteraless_bridge` на iOS; MockBackend в тестах на десктопе).

Слой намеренно «разрешающий», как Chaquopy jclass: любой член -> вызов
бэкенда; ошибки решает бэкенд. Манифест (tools/compat) используется для
валидации поверхности, а не для гейта на хот-пате.
"""

from .proxy import JavaClass, JavaInstance, get_class, reset_caches
from .backend import Backend, MockBackend, JavaMemberError
from .finder import install, uninstall, JAVA_ROOTS, reset_class_cache

__all__ = [
    "JavaClass", "JavaInstance", "get_class",
    "Backend", "MockBackend", "JavaMemberError",
    "install", "uninstall", "JAVA_ROOTS",
    "reset_class_cache", "reset_caches",
]
