import ExteralessCore
import Foundation
import Postbox
import SwiftSignalKit

extension ExteralessRetentionMediaEntry {
    /// A real, separately owned native resource. UUID entropy supplies the native file id;
    /// admission checks both this account's manifest and MediaBox for a collision.
    var cacheFileId: Int64 { Self.cacheFileId(token: self.token) }
    var cacheId: MediaResourceId { LocalFileMediaResource(fileId: self.cacheFileId).id }

    static func cacheFileId(token: String) -> Int64 {
        let digits = token.replacingOccurrences(of: "-", with: "")
        return Int64(bitPattern: UInt64(digits.prefix(16), radix: 16) ?? 0)
    }
}

/// Archive rendering must not cause a new cloud fetch for a file the client never received.
/// These are stock LocalFileMediaResources backed exclusively by the encrypted archive fetcher.
/// The complete original metadata stays in the encrypted snapshot for the details/export UI.
func exteralessRetentionLocalMedia(_ media: Media, index: ExteralessRetentionIndex, depth: Int = 0) -> Media? {
    guard depth < 8 else { return nil }
    func resource(_ value: MediaResource) -> TelegramMediaResource? {
        guard let entry = index.media[value.id.stringRepresentation] else { return nil }
        return exteralessRetentionLocalResource(entry: entry, index: index, size: entry.storedBytes ?? value.size)
    }
    func representation(_ value: TelegramMediaImageRepresentation) -> TelegramMediaImageRepresentation? {
        guard let local = resource(value.resource) else { return nil }
        return TelegramMediaImageRepresentation(dimensions: value.dimensions, resource: local, progressiveSizes: value.progressiveSizes, immediateThumbnailData: value.immediateThumbnailData, hasVideo: value.hasVideo, isPersonal: value.isPersonal, typeHint: value.typeHint)
    }
    if let image = media as? TelegramMediaImage {
        let representations = image.representations.compactMap(representation)
        guard !representations.isEmpty || image.immediateThumbnailData != nil else { return nil }
        return TelegramMediaImage(imageId: image.imageId, representations: representations, videoRepresentations: image.videoRepresentations.compactMap { value in
            guard let local = resource(value.resource) else { return nil }
            return TelegramMediaImage.VideoRepresentation(dimensions: value.dimensions, resource: local, startTimestamp: value.startTimestamp)
        }, immediateThumbnailData: image.immediateThumbnailData, emojiMarkup: nil, reference: nil, partialReference: nil, flags: image.flags,
        video: image.video.flatMap { exteralessRetentionLocalMedia($0, index: index, depth: depth + 1) as? TelegramMediaFile })
    }
    if let file = media as? TelegramMediaFile {
        guard let local = resource(file.resource) else { return nil }
        return TelegramMediaFile(fileId: file.fileId, partialReference: nil, resource: local, previewRepresentations: file.previewRepresentations.compactMap(representation), videoThumbnails: file.videoThumbnails.compactMap { value in
            guard let local = resource(value.resource) else { return nil }
            return TelegramMediaFile.VideoThumbnail(dimensions: value.dimensions, resource: local)
        }, videoCover: file.videoCover.flatMap { exteralessRetentionLocalMedia($0, index: index, depth: depth + 1) as? TelegramMediaImage }, immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: file.size, attributes: file.attributes,
        alternativeRepresentations: file.alternativeRepresentations.compactMap { exteralessRetentionLocalMedia($0, index: index, depth: depth + 1) as? TelegramMediaFile })
    }
    if let paid = media as? TelegramMediaPaidContent {
        let values = paid.extendedMedia.compactMap { item -> TelegramExtendedMedia? in
            if case let .full(media) = item, let mapped = exteralessRetentionLocalMedia(media, index: index, depth: depth + 1) { return .full(media: mapped) }
            return nil
        }
        return values.isEmpty ? nil : TelegramMediaPaidContent(amount: paid.amount, extendedMedia: values)
    }
    if let poll = media as? TelegramMediaPoll {
        func local(_ value: Media) -> Media? { exteralessRetentionLocalMedia(value, index: index, depth: depth + 1) }
        let options = poll.options.map { option in
            TelegramMediaPollOption(text: option.text, entities: option.entities, opaqueIdentifier: option.opaqueIdentifier, media: option.media.flatMap(local), date: option.date, addedBy: option.addedBy)
        }
        let solution = poll.results.solution.map { value in
            TelegramMediaPollResults.Solution(text: value.text, entities: value.entities, media: value.media.flatMap(local))
        }
        let results = TelegramMediaPollResults(voters: poll.results.voters, totalVoters: poll.results.totalVoters, recentVoters: poll.results.recentVoters, solution: solution, hasUnseenVotes: poll.results.hasUnseenVotes, canViewStats: poll.results.canViewStats)
        return TelegramMediaPoll(pollId: poll.pollId, publicity: poll.publicity, kind: poll.kind, text: poll.text, textEntities: poll.textEntities, options: options, correctAnswers: poll.correctAnswers, results: results, isClosed: poll.isClosed, deadlineTimeout: poll.deadlineTimeout, deadlineDate: poll.deadlineDate, pollHash: poll.pollHash, openAnswers: poll.openAnswers, revotingDisabled: poll.revotingDisabled, shuffleAnswers: poll.shuffleAnswers, hideResultsUntilClose: poll.hideResultsUntilClose, isCreator: poll.isCreator, attachedMedia: poll.attachedMedia.flatMap(local), restrictToSubscribers: poll.restrictToSubscribers, countries: poll.countries)
    }
    if let webpage = media as? TelegramMediaWebpage, case let .Loaded(value) = webpage.content {
        let content = TelegramMediaWebpageLoadedContent(url: value.url, displayUrl: value.displayUrl, hash: value.hash, type: value.type, websiteName: value.websiteName, title: value.title, text: value.text, embedUrl: nil, embedType: nil, embedSize: nil, duration: value.duration, author: value.author, isMediaLargeByDefault: value.isMediaLargeByDefault, imageIsVideoCover: value.imageIsVideoCover,
            image: value.image.flatMap { exteralessRetentionLocalMedia($0, index: index, depth: depth + 1) as? TelegramMediaImage },
            file: value.file.flatMap { exteralessRetentionLocalMedia($0, index: index, depth: depth + 1) as? TelegramMediaFile }, story: nil, attributes: [], instantPage: nil)
        return TelegramMediaWebpage(webpageId: webpage.webpageId, content: .Loaded(content))
    }
    // Pending web pages, games, invoices and story pointers can perform hidden network/image fetches.
    // Their received descriptions remain in the snapshot/attachment list. Render media only
    // when every resource boundary is local; poll question/option/solution media is mapped above.
    if media is TelegramMediaWebpage || media is TelegramMediaStory || media is TelegramMediaGame || media is TelegramMediaInvoice || media is TelegramMediaWebFile { return nil }
    return media
}

private final class ExteralessRetentionCopyResource: MediaResourceDataFetchCopyLocalItem {
    let file: ExteralessRetainedResourceFile
    init(_ file: ExteralessRetainedResourceFile) { self.file = file }

    func copyTo(url: URL) -> Bool {
        do {
            if self.file.url.standardizedFileURL != url.standardizedFileURL {
                try FileManager.default.copyItem(at: self.file.url, to: url)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value == self.file.byteCount && self.file.byteCount > 0
        } catch { return false }
    }
}

/// Insert at the beginning of State/Fetch.fetchResource. nil means an ordinary local resource,
/// not ours. Owned but absent/corrupt files terminate with .generic, never success or .never().
func exteralessFetchRetainedLocalResource(postbox: Postbox, resource: MediaResource) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError>? {
    let sourceId: String
    let provenance: RetentionResourceProvenance?
    let owner: ExteralessRetentionAccount
    if let retained = resource as? ExteralessRetainedLocalFileMediaResource {
        guard let tag = retained.retentionProvenance,
              RetentionMediaOwnership.nativeId(token: tag.token) == resource.id.stringRepresentation,
              let current = ExteralessRetentionAccount.get(mediaBox: postbox.mediaBox), current.accountPeerId.toInt64() == tag.accountPeerId else { return .fail(.generic) }
        sourceId = tag.sourceId; provenance = tag; owner = current
    } else {
        guard resource is LocalFileMediaResource, let current = ExteralessRetentionAccount.get(mediaBox: postbox.mediaBox),
              let currentSource = current.sourceId(forArchiveResource: resource.id) else { return nil }
        sourceId = currentSource; provenance = nil; owner = current
    }
    return owner.materialize(resourceId: sourceId, provenance: provenance)
    |> castError(MediaResourceDataFetchError.self)
    |> mapToSignal { result -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> in
        switch result {
        case let .success(file): return .single(.copyLocalItem(ExteralessRetentionCopyResource(file)))
        case .failure: return .fail(.generic)
        }
    }
}
