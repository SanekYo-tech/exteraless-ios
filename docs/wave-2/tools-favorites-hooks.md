# Local favorite stickers — exact normal-picker hooks for the stickers owner

Ready source APIs live in
`TelegramCore/Sources/ExteralessTools/ToolsLocalFavoriteStickers.swift`:

```swift
exteralessLocalFavoriteStickers(engine:) -> Signal<ExteralessLocalFavoriteSnapshot, ToolsError>
exteralessLocalFavoriteStickerItems(engine:) -> Signal<[SavedStickerItem], ToolsError>
exteralessImportLocalFavoriteStickers(engine:archive:) -> Signal<Int, ToolsError>
exteralessSetLocalFavoriteSticker(engine:file:saved:) -> Signal<Bool, ToolsError>
exteralessRemoveLocalFavoriteSticker(engine:id:) -> Signal<Bool, ToolsError>
```

The store is a distinct account-local preference, **not** CloudSavedStickers and
not a server quota override. Tools UI already exports/imports/merges/removes real
data and opens native packs. Only the shared picker/menu insertion remains yours.
No untrusted archive bytes enter SavedStickerItem's generic FlatBuffer decoder.

## `EntityKeyboard/Sources/EmojiPagerContentSignals.swift`

Current source already contains your `localRecentStickers` / `stickerPolicy` inputs
to `stickerInputData` (near 1729). Add the local favorite signal as one more input;
on failure log a safe storage error and show only the already-existing cloud list
(the Tools screen surfaces the actual local error; don't label that a successful
empty local import):

```swift
let localFavorites = exteralessLocalFavoriteStickerItems(engine: context.engine)
    |> `catch` { _ -> Signal<[SavedStickerItem], NoError> in
        Logger.shared.log("ExteralessFavorites", "Local favorite storage unavailable")
        return .single([])
    }
// Add localFavorites to the existing combineLatest; add localFavoriteStickers
// to its map closure without replacing the recent/GIF/policy inputs.
```

Directly after building `savedStickers` / before the existing saved group renderer:

```swift
let cloudFavoriteIds = Set(savedStickers?.items.compactMap {
    $0.contents.get(SavedStickerItem.self)?.file.fileId
} ?? [])
let localOnlyFavorites = localFavoriteStickers.filter { !cloudFavoriteIds.contains($0.file.fileId) }
```

Immediately after the existing `if let savedStickers` block (before recent items),
append the local-only items to the same `saved` group or create it if no cloud item
exists. This is the existing item construction with a **native pack/standalone**
reference instead of wrongly claiming every locally kept item is server-saved:

```swift
for item in localOnlyFavorites {
    if isPremiumDisabled && item.file.isPremiumSticker { continue }
    let file = item.file._parse() // already-trusted native object, not archive bytes
    let animationData = EntityKeyboardAnimationData(file: item.file, partialReference: file.partialReference)
    let resultItem = EmojiPagerContentComponent.Item(animationData: animationData,
        content: .animation(animationData), itemFile: item.file, subgroupId: nil,
        icon: .none, tintMode: item.file.isCustomTemplateEmoji ? .primary : .none)
    let groupId = "saved"
    if let index = itemGroupIndexById[groupId] { itemGroups[index].items.append(resultItem) }
    else {
        itemGroupIndexById[groupId] = itemGroups.count
        itemGroups.append(ItemGroup(supergroupId: groupId, id: groupId,
            title: strings.EmojiInput_SectionTitleFavoriteStickers, subtitle: nil,
            actionButtonTitle: nil, isPremiumLocked: false, isFeatured: false,
            displayPremiumBadges: false, hasEdit: false, headerItem: nil, items: [resultItem]))
    }
}
```

For an explicit **Keep local favorite / Remove local favorite** menu action, use
`exteralessSetLocalFavoriteSticker(engine:file:saved:)` and complete UI only after
its Signal value/error. It performs a real local transaction and never calls a
favorite/send RPC. Keep Telegram's ordinary cloud-favorite action and its actual
limit/result distinct. If integrating a global “local/unlimited” preference, wire
that preference to this branch and its saved-state lookup, not to a cosmetic count.

Needed source verification: 300+ local records survive a cloud refresh; duplicates
do not produce two grid cells; a different account has its own list; expired file
references use the stored pack reference when available; imports/writes fail without
clobbering corrupt records. Tools supplied portable archive fixtures; native picker
frames and this owner's signal insertion remain unverified.
