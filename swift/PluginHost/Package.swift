// swift-tools-version:6.0
import PackageDescription

// ЭТАП 4: нативная (Swift) сторона плагин-системы exteraless для iOS-порта.
//
// Пакет собирается БЕЗ CPython: все обращения к CPython идут через протокол
// `CPythonEngine` (см. PythonRuntime.swift). Это позволяет гонять логику
// (очередь, коалесценг, сторож, модель, разрешения) в тестах на Linux-CI
// бесплатно — принцип 5 архитектуры («тесты как оракул + экономия
// macOS-минут»). Настоящая реализация движка линкуется в Bazel-сборке
// telegram-ios к Python.xcframework — план в README.md.
//
// Врезка в telegram-ios — НЕ через SPM-зависимость, а напрямую Bazel-таргетами
// из Sources/ (swift_library + cc_library для шима атомиков): см. README.
let package = Package(
    name: "PluginHost",
    platforms: [.macOS(.v12), .iOS(.v14)],
    products: [
        .library(name: "PluginHost", targets: ["PluginHost"]),
    ],
    targets: [
        .target(name: "CPluginHostShims"),
        .target(name: "PluginHost", dependencies: ["CPluginHostShims"]),
        .testTarget(name: "PluginHostTests", dependencies: ["PluginHost"]),
    ]
)
