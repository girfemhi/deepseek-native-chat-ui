import Foundation
import UniformTypeIdentifiers
@preconcurrency import UIKit
@preconcurrency import ExyteMediaPicker

struct ImportedPastePayload: Sendable {
    var medias: [(Media, URL)] = []
    var documents: [(DocumentItem, URL)] = []
    var textFragments: [String] = []

    var ownedURLs: [URL] {
        medias.map(\.1) + documents.map(\.1)
    }
}

struct SendableItemProvider: @unchecked Sendable {
    let index: Int
    let provider: NSItemProvider
}

enum PastedContentImporter {
    static let filenamePrefix = "DSH-exyte-paste-"
    static let maximumItemBytes: Int64 = 1_024 * 1_024 * 1_024
    private static let freeSpaceReserve: Int64 = 32 * 1_024 * 1_024

    private struct StagedFile {
        let url: URL
        let sourceFileName: String?
    }

    static func containsAttachment(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.registeredTypeIdentifiers.contains { identifier in
                guard let type = UTType(identifier) else { return false }
                return type == .fileURL
                    || type.conforms(to: .image)
                    || type.conforms(to: .movie)
                    || (type.conforms(to: .data)
                        && !type.conforms(to: .text)
                        && !type.conforms(to: .url))
            }
        }
    }

    static func importProviders(_ wrapped: [SendableItemProvider]) async -> ImportedPastePayload {
        var ordered: [(Int, ImportedPastePayload)] = []
        await withTaskGroup(of: (Int, ImportedPastePayload).self) { group in
            for item in wrapped {
                group.addTask { (item.index, await importProvider(item)) }
            }
            for await result in group { ordered.append(result) }
        }
        return ordered.sorted { $0.0 < $1.0 }.reduce(into: ImportedPastePayload()) { result, value in
            result.medias.append(contentsOf: value.1.medias)
            result.documents.append(contentsOf: value.1.documents)
            result.textFragments.append(contentsOf: value.1.textFragments)
        }
    }

    static func deleteOwned(_ urls: some Sequence<URL>) {
        for url in urls where isOwned(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func isOwned(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent() == FileManager.tempDirPath.standardizedFileURL
            && standardized.lastPathComponent.hasPrefix(filenamePrefix)
    }

    private static func importProvider(_ item: SendableItemProvider) async -> ImportedPastePayload {
        if item.provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let result = await loadAndStageFileURL(item) {
            return result
        }

        let types = item.provider.registeredTypeIdentifiers.compactMap(UTType.init)
        let attachmentType = types.first { isSpecificAttachmentType($0) }
            ?? types.first { $0.conforms(to: .image) || $0.conforms(to: .movie) }
            ?? types.first {
                $0 != .fileURL
                    && $0.conforms(to: .data)
                    && !$0.conforms(to: .text)
                    && !$0.conforms(to: .url)
            }
        if let attachmentType,
           let staged = await loadAndStage(item, type: attachmentType),
           let result = makePayload(
               url: staged.url,
               provider: item.provider,
               type: attachmentType,
               fallbackFileName: staged.sourceFileName
           ) {
            return result
        }

        if let text = await loadText(item), !text.isEmpty {
            return ImportedPastePayload(textFragments: [text])
        }
        return ImportedPastePayload()
    }

    private static func loadAndStage(_ item: SendableItemProvider, type: UTType) async -> StagedFile? {
        await withCheckedContinuation { continuation in
            item.provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    item.provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                        guard let data else { continuation.resume(returning: nil); return }
                        if !type.conforms(to: .propertyList),
                           let source = decodeFileURLRepresentation(data),
                           (item.provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                               || (!isGenericRepresentation(type)
                                   && representationMatchesSource(source, representationType: type))) {
                            continuation.resume(returning: copyToOwnedStage(source, provider: item.provider, type: type).map {
                                StagedFile(url: $0, sourceFileName: source.lastPathComponent)
                            })
                            return
                        }
                        continuation.resume(returning: stage(data: data, provider: item.provider, type: type).map {
                            StagedFile(url: $0, sourceFileName: nil)
                        })
                    }
                    return
                }
                // iOS pasteboard may strip the public.file-url declaration while still returning
                // its exact, private three-field URL wrapper for a specific representation (PDF,
                // DOCX, and so on). The decoder below validates that narrow schema and verifies the
                // resolved source against the requested concrete type before following it.
                let wrappedSource = legacyWrappedFileURL(from: url, representationType: type)
                let source = wrappedSource ?? url
                continuation.resume(returning: copyToOwnedStage(source, provider: item.provider, type: type).map {
                    StagedFile(url: $0, sourceFileName: wrappedSource?.lastPathComponent)
                })
            }
        }
    }

    private static func loadAndStageFileURL(_ item: SendableItemProvider) async -> ImportedPastePayload? {
        await withCheckedContinuation { continuation in
            item.provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                if let url = value as? URL, url.isFileURL {
                    let wrappedSource = isPropertyListFileURL(url)
                        ? nil
                        : legacyWrappedFileURL(from: url, representationType: .fileURL)
                    if wrappedSource == nil, containsLegacyWrapperPayload(url) {
                        continuation.resume(returning: nil)
                        return
                    }
                    let source = wrappedSource ?? url
                    continuation.resume(returning: stageFile(
                        at: source,
                        provider: item.provider,
                        type: UTType(filenameExtension: source.pathExtension),
                        fallbackFileName: source.lastPathComponent
                    ))
                    return
                }
                if let data = value as? Data,
                   let url = decodeFileURLRepresentation(data) {
                    continuation.resume(returning: stageFile(
                        at: url,
                        provider: item.provider,
                        type: UTType(filenameExtension: url.pathExtension),
                        fallbackFileName: url.lastPathComponent
                    ))
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func loadText(_ item: SendableItemProvider) async -> String? {
        guard item.provider.canLoadObject(ofClass: NSString.self) else { return nil }
        return await withCheckedContinuation { continuation in
            item.provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map(String.init))
            }
        }
    }

    private static func decodeFileURLRepresentation(_ data: Data) -> URL? {
        guard data.count <= 64 * 1_024 else { return nil }
        if data.starts(with: Data("bplist00".utf8)) {
            if let value = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) {
                let url = value as URL
                if url.isFileURL { return url }
            }
            return legacyFileURL(fromPropertyListData: data)
        }
        if let string = String(data: data, encoding: .utf8),
           string.hasPrefix("file://"),
           let url = URL(string: string), url.isFileURL {
            return url
        }
        return nil
    }

    private static func legacyWrappedFileURL(from url: URL, representationType: UTType) -> URL? {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        guard !representationType.conforms(to: .propertyList),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= 64 * 1_024,
              let data = try? Data(contentsOf: url),
              data.starts(with: Data("bplist00".utf8)),
              let source = legacyFileURL(fromPropertyListData: data),
              representationMatchesSource(source, representationType: representationType) else { return nil }
        return source
    }

    private static func containsLegacyWrapperPayload(_ url: URL) -> Bool {
        if isPropertyListFileURL(url) { return false }
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= 64 * 1_024,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        return data.starts(with: Data("bplist00".utf8))
    }

    private static func isPropertyListFileURL(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty,
              let sourceType = UTType(filenameExtension: url.pathExtension) else { return false }
        return sourceType.conforms(to: .propertyList)
    }

    private static func isGenericRepresentation(_ type: UTType) -> Bool {
        type == .data || type == .item || type == .content || type == .url || type == .fileURL
    }

    private static func legacyFileURL(fromPropertyListData data: Data) -> URL? {
        guard data.count <= 64 * 1_024,
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = root as? [Any],
              values.count == 3,
              let path = values[0] as? String,
              path.hasPrefix("file://"),
              let metadata = values[1] as? String,
              metadata.isEmpty,
              let options = values[2] as? [AnyHashable: Any],
              options.isEmpty,
              let url = URL(string: path),
              url.isFileURL else { return nil }
        return url
    }

    private static func representationMatchesSource(_ source: URL, representationType: UTType) -> Bool {
        let accessedSecurityScope = source.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope { source.stopAccessingSecurityScopedResource() }
        }
        if isGenericRepresentation(representationType) {
            return true
        }
        if representationType == .pdf {
            guard let handle = try? FileHandle(forReadingFrom: source) else { return false }
            defer { try? handle.close() }
            return ((try? handle.read(upToCount: 5)) ?? nil)?.starts(with: Data("%PDF".utf8)) == true
        }
        guard !source.pathExtension.isEmpty,
              let sourceType = UTType(filenameExtension: source.pathExtension) else { return false }
        return sourceType == representationType || sourceType.conforms(to: representationType)
    }

    private static func stageFile(
        at url: URL,
        provider: NSItemProvider,
        type: UTType?,
        fallbackFileName: String? = nil
    ) -> ImportedPastePayload? {
        guard url.isFileURL,
              let staged = copyToOwnedStage(url, provider: provider, type: type) else { return nil }
        return makePayload(url: staged, provider: provider, type: type, fallbackFileName: fallbackFileName)
    }

    private static func copyToOwnedStage(_ source: URL, provider: NSItemProvider, type: UTType?) -> URL? {
        let accessedSecurityScope = source.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope { source.stopAccessingSecurityScopedResource() }
        }
        guard source.isFileURL,
              let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        let fileSize = Int64(values.fileSize ?? 0)
        guard fileSize >= 0, fileSize <= maximumItemBytes, hasCapacity(for: fileSize) else { return nil }
        let destination = destinationURL(provider: provider, type: type, sourceExtension: source.pathExtension)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            guard let stagedValues = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  stagedValues.isRegularFile == true,
                  stagedValues.isSymbolicLink != true else {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    private static func stage(data: Data, provider: NSItemProvider, type: UTType) -> URL? {
        guard Int64(data.count) <= maximumItemBytes, hasCapacity(for: Int64(data.count)) else { return nil }
        let destination = destinationURL(provider: provider, type: type, sourceExtension: nil)
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    private static func hasCapacity(for bytes: Int64) -> Bool {
        let values = try? FileManager.tempDirPath.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return capacity >= bytes + freeSpaceReserve
    }

    private static func destinationURL(provider: NSItemProvider, type: UTType?, sourceExtension: String?) -> URL {
        let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = suggested?.isEmpty == false ? suggested! : "Pasted attachment"
        let sanitized = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var destination = FileManager.tempDirPath.appendingPathComponent(filenamePrefix + UUID().uuidString + "-" + sanitized)
        if destination.pathExtension.isEmpty,
           let ext = sourceExtension?.isEmpty == false ? sourceExtension : type?.preferredFilenameExtension {
            destination.appendPathExtension(ext)
        }
        return destination
    }

    private static func makePayload(
        url: URL,
        provider: NSItemProvider,
        type: UTType?,
        fallbackFileName: String? = nil
    ) -> ImportedPastePayload? {
        let resolved = resolvedContentType(type, url: url)
        if resolved?.conforms(to: .movie) == true || isSupportedBitmap(resolved, url: url) {
            let mediaType: MediaType = resolved?.conforms(to: .movie) == true ? .video : .image
            let media = Media(source: PastedMediaModel(url: url, mediaType: mediaType))
            return ImportedPastePayload(medias: [(media, url)])
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        let document = DocumentItem(
            url: url,
            fileName: displayName(provider: provider, type: resolved, fallbackFileName: fallbackFileName),
            fileSize: size,
            contentTypeIdentifier: resolved?.identifier
        )
        return ImportedPastePayload(documents: [(document, url)])
    }

    private static func isSpecificAttachmentType(_ type: UTType) -> Bool {
        guard type.conforms(to: .data), !type.conforms(to: .text), !type.conforms(to: .url) else { return false }
        return type != .data && type != .item && type != .content
    }

    private static func resolvedContentType(_ type: UTType?, url: URL) -> UTType? {
        if let type, type != .data, type != .item, type != .content { return type }
        if let extType = UTType(filenameExtension: url.pathExtension), !url.pathExtension.isEmpty {
            return extType
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return type }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 16)) ?? nil
        guard let prefix else { return type }
        if prefix.starts(with: Data("%PDF".utf8)) { return .pdf }
        if prefix.starts(with: Data("GIF87a".utf8)) || prefix.starts(with: Data("GIF89a".utf8)) { return .gif }
        if prefix.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) { return .png }
        if prefix.starts(with: Data([0xFF, 0xD8, 0xFF])) { return .jpeg }
        return type
    }

    private static func displayName(provider: NSItemProvider, type: UTType?, fallbackFileName: String?) -> String {
        if let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            return suggested
        }
        if let fallbackFileName, !fallbackFileName.isEmpty {
            return fallbackFileName
        }
        let base = "Pasted file"
        guard let ext = type?.preferredFilenameExtension, !ext.isEmpty else { return base }
        return base + "." + ext
    }

    private static func isSupportedBitmap(_ type: UTType?, url: URL) -> Bool {
        guard type?.conforms(to: .image) == true else { return false }
        let ext = (type?.preferredFilenameExtension ?? url.pathExtension).lowercased()
        return ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"].contains(ext)
    }
}

actor PastedMediaModel: MediaModelProtocol {
    nonisolated let url: URL
    nonisolated let mediaType: MediaType?

    init(url: URL, mediaType: MediaType) {
        self.url = url
        self.mediaType = mediaType
    }

    var duration: CGFloat? { nil }
    func getURL() async -> URL? { url }
    func getThumbnailURL() async -> URL? { url }
    func getData() async throws -> Data? { try Data(contentsOf: url) }
    func getThumbnailData() async -> Data? { try? Data(contentsOf: url) }
}
