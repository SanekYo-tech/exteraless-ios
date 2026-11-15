import Foundation
import SwiftSignalKit

/// Empty only at the presentation boundary. The provider retains its native
/// cache, pagination cursor, published stories and server read state.
func exteralessDialogStoryListStates(_ source: Signal<StoryListContext.State, NoError>) -> Signal<StoryListContext.State, NoError> {
    return combineLatest(source, exteralessDialogPolicyUpdates() |> map { !$0.disableStories } |> distinctUntilChanged)
    |> map { state, enabled in
        guard !enabled else { return state }
        var display = state
        display.items = []
        display.availableFolders = []
        display.pinnedIds = []
        display.totalCount = 0
        display.loadMoreToken = nil
        display.isLoading = false
        return display
    }
}
