"""Original Java SDK static entry points backed by the iOS platform providers."""

import json

from ._java_types import Object, ArrayList
from ._platform import UnsupportedSurfaceError


def install(platform, base, services, client):
    from virtualjava import register_class

    class ServiceMeta(type):
        def __getattr__(cls, name):
            if name.startswith("_"): raise AttributeError(name)
            return getattr(services, name)
    class PluginServices(metaclass=ServiceMeta):
        def __new__(cls): raise TypeError("PluginServices is a static facade")

    class BridgeMeta(type):
        def __getattr__(cls, name):
            if name.startswith("_"): raise AttributeError(name)
            return getattr(platform, name)
    class PythonBridge(metaclass=BridgeMeta):
        def __new__(cls): raise TypeError("PythonBridge is a static facade")
        @staticmethod
        def getSdkVersion(): return "1.4.5.7"  # Original PluginsConstants.SDK_VERSION.
        @staticmethod
        def logStream(plugin_id, level, message):
            platform.check_plugin(plugin_id)
            return platform.call("logEvent", {"level": str(level), "message": str(message), "phase": "sdk"})

    class Controller(Object):
        @classmethod
        def getInstance(cls): return cls()
        def getPlugin(self, plugin_id):
            platform.check_plugin(str(plugin_id))
            return platform.loader.get_plugin_instance(str(plugin_id))
        def getPlugins(self):
            raise UnsupportedSurfaceError("the cross-plugin manager registry requires a native PluginHost snapshot")
        def getPluginsDir(self):
            from ._java_types import File
            return File(platform.getPluginsDir())
        def reloadSettingsScreen(self, plugin_id): return platform.reloadSettingsScreen(str(plugin_id))
        loadPluginSettings = reloadSettingsScreen
        def getPluginSettingsJson(self, plugin_id):
            platform.check_plugin(str(plugin_id))
            return platform.loader.get_settings_json(str(plugin_id))
        def clearPluginSettingsPreferences(self, plugin_id): return platform.update_settings(str(plugin_id), {}, replace=True, reload=True)
        def hasPluginSettingsPreferences(self, plugin_id): return bool(platform.get_settings(str(plugin_id)))
        def exportPluginSettings(self, plugin_id): return platform.exportSettings(str(plugin_id))
        def importPluginSettings(self, plugin_id, raw, reload=True): return platform.importSettings(str(plugin_id), raw, reload)
        def replacePluginSettings(self, plugin_id, raw): return platform.replaceSettings(str(plugin_id), raw)
        def openPluginSettings(self, plugin_id, target=None):
            platform.check_plugin(str(plugin_id))
            return platform.show_settings(target=target)

    class AndroidUtilities:
        @staticmethod
        def runOnUIThread(callback, delay=0): return client.run_on_ui_thread(callback, delay)
        @staticmethod
        def dp(value): return platform.call("dp", value, fqcn="org.telegram.messenger.AndroidUtilities")
        @staticmethod
        def dpf2(value): return platform.call("dpf2", value, fqcn="org.telegram.messenger.AndroidUtilities")
        @staticmethod
        def addToClipboard(text): return platform.call("addToClipboard", str(text))
        @staticmethod
        def getString(key, resource_id=None):
            if not isinstance(key, str): raise UnsupportedSurfaceError("Android string resource IDs need a native localization key")
            return platform.call("getString", key, fqcn="org.telegram.messenger.LocaleController")

    class ApplicationLoader:
        applicationContext = platform.ui_context
        @staticmethod
        def getFilesDirFixed(): return platform.ui_context.getFilesDir()
        getFilesDir = getFilesDirFixed
    class LaunchActivity:
        @staticmethod
        def getLastFragment(): return client.get_last_fragment()
        getLastFragmentIncludeMainTabs = getLastFragment

    class Browser:
        @staticmethod
        def openUrl(*args):
            if not args: raise TypeError("openUrl requires a URL")
            return platform.call("openURL", str(args[-1]))

    classes = {"app.exteraless.plugins.PluginServices": PluginServices,
               "app.exteraless.plugins.PythonBridge": PythonBridge,
               "app.exteraless.plugins.PluginsController": Controller,
               "org.telegram.messenger.AndroidUtilities": AndroidUtilities,
               "org.telegram.messenger.ApplicationLoader": ApplicationLoader,
               "org.telegram.ui.LaunchActivity": LaunchActivity,
               "org.telegram.messenger.browser.Browser": Browser}
    for name, cls in classes.items(): register_class(name, cls)
    base._PluginsControllerProxy._java = Controller
    platform.ui_context.getString = AndroidUtilities.getString
