# Unsigned IPA: сборка и проверка

## Причина последнего отказа

Прогон [43213573556](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43213573556)
на `eaeac765` остановился в `ProcessAndSign` для `IntentsExtension` и
`WidgetExtension`: `codesign ... no identity found`.

В командах этого прогона **уже был `HOME=/Users/runner`**. Предыдущее
объяснение отказа отсутствием HOME не подтвердилось. Успех шага импорта
также не доказывал наличие identity: `ImportCertificates.py` игнорировал
его ошибки. CI фактически собирал приложение с фейковой подписью, хотя
требуемый результат — unsigned IPA для последующей подписи пользователем.

## Новый путь

```sh
# На macOS с Xcode/Bazel из telegram-ios/versions.json, внутри telegram-ios:
python3 build-system/Make/Make.py \
  --cacheDir="$HOME/Library/Caches/exteraless-bazel-disk" \
  build --unsigned \
  --configurationPath=build-system/exteraless-configuration.json \
  --configuration=release_arm64 --buildNumber=42 \
  --outputBuildArtifactsPath=build/artifacts
```

`--unsigned` — отдельный взаимоисключающий режим `Make.py build`:

- не читает и не создаёт сертификаты, keychain или профили;
- включает `//Telegram:disableProvisioningProfiles`;
- включает штатный `disable_legacy_signing` у `rules_apple`;
- применяет узкий патч, отключающий встраивание профиля в iOS bundles,
  **только** под флагом `exteraless_unsigned_compilation`;
- сохраняет в графе все шесть штатных iOS-расширений;
- перед компиляцией выполняет `aquery` того же полного device-графа;
  проверяет команды упаковки, импорт frameworks, шаблоны скриптов и
  отсутствие действий, читающих provisioning profiles.

Патч: `telegram-ios/build-system/patches/unsigned-rules-apple.patch`.
Подготовка и preflight: `telegram-ios/build-system/Make/UnsignedBuild.py`.
Вход патча проверяется по нормализованному SHA-256 файла из закреплённого
`rules_apple` (`485016eb5b0948cc17307064e7977a6d68e94046`). Повторное применение
безопасно. SHA gitlink не меняется, патч накладывается на рабочую копию.
Подход пропуска profile embedding сверён с unsigned-build патчем VoidGram.

Отдельный watch-app pipeline `--embedWatchApp` пока несовместим с этим
режимом; он и раньше был выключен по умолчанию. Обычные iOS extensions
не отключаются.

## Выходные файлы

Workflow `.github/workflows/ios-build.yml` запускается только вручную.
Артефакты берутся из актуального `bazel-bin/Telegram/Telegram.ipa` через
`--outputBuildArtifactsPath`, без устаревшего `applebin_ios-*` glob.

- `Telegram.ipa` — для самостоятельной подписи;
- `Telegram.DSYMs.zip` — отладочные символы;
- `build-manifest.json` — версия, номер билда, SHA-256 и результаты проверок;
- `signing-entitlements/` — сгенерированные шаблоны прав для app/extensions;
- `Telegram_dossier.zip` — штатный dossier `rules_apple` с шаблонами прав
  и связями вложенных bundles; запрашивается output group `dossier`;
- отдельный `unsigned-preflight` artifact — граф и результаты ранней проверки.

`tools/ci/verify_unsigned_ipa.py` проверяет app + шесть extensions, пять
основных frameworks и вложенные dylib: ARM64 (включая fat slices), платформу
iOS device, версии app/extensions, целостность ZIP и отсутствие встроенных
профилей/подписи разработчика. Допускается ad-hoc подпись, которую может
добавлять сам линкер ARM64. Чтение поблочное, архив на диск не распаковывается.

Entitlements — запрос прав для последующей подписи, не выданные Apple
разрешения. Наличие сертификата у пользователя само по себе не гарантирует
APNs от серверов Telegram: требуется совместимость профиля, App ID/topic и
провайдерской APNs-конфигурации. IPA подписывает пользователь после сборки.

## Проверки и стоимость повторов

```powershell
# Windows; никаких импортов плагинов или сборки клиента:
$env:PYTHONUTF8 = "1"
python -m unittest discover -s tools/ci/tests -v
```

Эти тесты проверяют режим/аргументы Make.py, наложение патча, отсутствие
обращений к profiles в unsigned-режиме и проверку маленьких тестовых IPA.
Они не заменяют настоящую сборку на macOS.

Независимый аудит проверил схему по pinned rules_apple. До запуска CI
исправлены два найденных места: у unsigned `ProcessAndSign` нет аргумента
`should_not_sign` (нужно проверять отсутствие `should_sign`), а для создания
шаблонов entitlements требуется явный output group `dossier`. Локально
25 тестов прошли на Python 3.12; плагины для этих проверок не исполнялись.

CI сохраняет Bazel disk action cache и при последующем отказе сборки.
Раньше `actions/cache` сохранял его только после полностью успешной джобы,
поэтому каждый отказ терял результаты уже выполненных действий.
Ключ восстановления привязан к платформе, версии toolchain и пинам зависимостей;
content-addressed ключи Bazel определяют пригодность отдельных результатов.

Не объявлять сборку готовой по успеху preflight: завершение — успешный
полный build, проверенный IPA и публикация артефакта.
