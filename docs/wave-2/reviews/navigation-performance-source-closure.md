# PNP-01/02/03 — independent source closure

2026-11-15. **Все три прежних контрпримера source-closed; оставшихся P1/P2 по ним не найдено.** Проверен actual working tree при HEAD `2bac089c113dde061d86891e073ee08558a35d86`, включая опубликованные `19c1a96a` и `b06f959b`. Основание — `portable-navigation-performance.md` и текущие production/fixture sources.

**Native execution и recorded frames — pending.** Этот вывод не является результатом исполнения XCTest или визуальной приёмкой.

Сокращения: `D/` = `telegram-ios/submodules/Display/`; `U/` = `telegram-ios/submodules/TelegramUI/Components/`; `S/` = `telegram-ios/third-party/subcodec/`.

## PNP-01 — CLOSED (source), `19c1a96a`

- `D/Source/Navigation/NavigationController.swift:367–406,704–715` создаёт одноразовый generation-scoped adoption для сохранённого controller. `NavigationContainer.swift:648–694,1047–1053` отличает adoption во всех прежних местах обнуления keyboard inset: pending preparation, `makeChild`, ready promotion и regular-width `ignoreInputHeight`.
- Поэтому прежний Auto → Phone контрпример с `inputHeight=500` больше не проходит через fresh-push nil-layout. Используется текущий supplied pane layout; genuinely new push сохраняет штатную suppression.
- `NavigationContainer.swift:759–764` сообщает attachment **после** последнего `applyLayout`. Root выполняет guarded reconciliation по latest `validLayout` (`NavigationController.swift:383–406,1597–1605`) также при уже активном responder. При delayed ready сохранённый token проходит identity/generation check (`NavigationContainer.swift:1111–1115`).
- `NavigationContentLayout.swift:98–131` сохраняет настоящий responder/window и offsets `selectedTextRange`; восстановление учитывает текущий focus, другой responder и длину документа.

**Fixtures:** три новых метода в `D/Tests/AppearanceLayoutModeTests.swift:312–400`, с реальными `UITextField`/`UITextView`, test-owned UIWindow и 500pt input view (`:29–138`). Проверяются все delivered insets сразу после switch, настоящий focus/selection, delayed-ready + resize, pending Phone→Tablet→Phone, fresh push и popped-controller late-ready. После ready тест не делает ремонтирующий layout-вызов. Это actual-path assertions, пока не executed results.

## PNP-02 — CLOSED (source), `b06f959b`

- `U/DCTMultiAnimationRendererImpl/Sources/DCTMultiAnimationRendererImpl.swift:586–605,623–655` больше не делит elapsed на shrinking remainder. Sub-frame time уменьшает остаток; на границе worker вызывает настоящий cache `.frames(1)` и учитывает duration каждого возвращённого source frame.
- Для прежних `15 ms + 18⅓ ms` после primed 60-fps frame получается **два реальных advances**, а не `.frames(11)`. Carry сохраняется и для переменных durations; Float32 boundary tolerance — 100 ns.
- Elapsed поступает в debt до проверки pending task (`:591–594`). Completion вычитает только свою reservation и только в том же elapsed epoch (`:671–678`); новые ticks за время worker/completion не теряются и не потребляются повторно. Сохранились пределы 250 ms / 64 actual reads и final target/effects veto (`:438–444,641–655,682–695`).

**Fixtures:** пять методов `U/DCTMultiAnimationRendererImpl/Tests/ToolsDCTRendererTimingTests.swift:118–194`. Setup использует настоящий `DCTAnimationCacheImpl` writer и отдельный accessor для reference pixels (`:64–115`); production `ItemAnimationContext`/worker/completion исполняет проверяемый алгоритм. Assertions покрывают исходную пару ticks, jittered 30/60 Hz, held decode/completion с exact-once drain, variable durations/limits и queued-delivery veto. Source-frame identity определяется по декодированным различимым 16×16 изображениям.

## PNP-03 — CLOSED (source), `b06f959b`

- `U/SubcodecMultiAnimationRendererImpl/Sources/SubcodecMultiAnimationRendererImpl.swift:251–314` теперь выполняет **mark → emit внутри каждого source-step round**. В прежнем Average/60-fps контрпримере два required steps дают два emits. Frame-0 introduction учитывается отдельно; provisional indices/durations публикуются только после успешного полного decode. Target получает только конечный кадр tick (`:321–349`).
- Проверен фактический unchanged mux contract: `S/src/mux_surface.cpp:407–414,428–432,458–466`. Bool-mark больше не принимается за уже выполненный advance.
- Bulk `SCVideoToolboxDecoder` действительно создаёт session на каждый вызов и требует SPS/PPS (`S/Sources/SubcodecObjC/SCVideoToolboxDecoder.mm:187–235,292–303`). Renderer передаёт полную bounded dependency window, затем делает same-capacity I_PCM checkpoint штатным `resize` (`renderer:169–221`). Context identity/current slots сохраняются при compaction. Лимиты: 8 dependency frames, 32 MiB stream, 64 MiB decoded planes, 250 ms; replay/checkpoints входят в 64 actual decoder frames на tick (`:67–72,160–178,251–261,308–320`).

**Fixtures:** четыре метода `U/SubcodecMultiAnimationRendererImpl/Tests/ToolsSubcodecRendererTimingTests.swift:122–210`. Настоящий `SCSprite.extractor` создаёт локальный MBS; metadata читается штатным cache. Независимый reference делает один mark/emit на кадр и использует `SCOpenH264Decoder` (`:43–88`). Assertions сравнивают реальные VideoToolbox pixels с reference (`:113–119`), проверяют 30/60 Hz/loops, одну delivery за tick, per-target veto, compaction/paused pixels и decoder-work bound. Проверка не ограничена Swift counters.

## Read-only verification

- Прочитаны PNP-разделы `layout-mode-parity.md`, `performance-parity.md`, `performance-native-fixtures.json` и `performance-pnp-postimages.json`.
- Bounded Python **10 s**, только чтение: совпали **4/4** изменённых Navigation source/fixture pins из `layout-mode-source.sha256`, **4/4** renderer/fixture postimages и **4/4** preserved hashes — Core performance tests, DCT cache, VideoToolbox decoder, mux. Оба fix commits входят в ancestry текущего HEAD.
- Подтверждены **3** новых Navigation и **9** renderer XCTest methods на указанных actual paths. Native tests/frames здесь не запускались. Отдельный Darwin storage Core failure из сообщения owner не меняет PNP verdict.
- Изменён только этот отчёт.
