import Foundation

enum FileStreamerError: Error, LocalizedError {
    case deinitialized
    case offsetOutOfRange(offset: UInt64, fileSize: UInt64)
    case cannotOpenFile(URL)
    case systemError(Error)

    var errorDescription: String? {
        switch self {
        case .deinitialized:
            return "The file streamer was deinitialized before the operation completed."
        case let .offsetOutOfRange(offset, fileSize):
            return "Requested offset \(offset) is beyond file size \(fileSize)."
        case let .cannotOpenFile(url):
            return "Cannot open file for reading at \(url.path)."
        case let .systemError(error):
            return error.localizedDescription
        }
    }
}

// Uses a serial queue to serialize all non-Sendable FileHandle operations across concurrent requests.
final class FileStreamer: @unchecked Sendable {
    let fileURL: URL
    let fileSize: UInt64

    private let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "com.tsplayerkit.filestreamer")

    init(fileURL: URL) throws {
        self.fileURL = fileURL

        do {
            self.fileHandle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw FileStreamerError.cannotOpenFile(fileURL)
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            self.fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        } catch {
            try? fileHandle.close()
            throw FileStreamerError.systemError(error)
        }
    }

    // No custom deinit: FileHandle closes its file descriptor in its own
    // dealloc. (A previous version ran `queue.sync` from deinit, which crashes
    // libdispatch if the last strong reference is released on that queue.)

    func readBytes(offset: UInt64, length: UInt64) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: FileStreamerError.deinitialized)
                    return
                }

                let clampedOffset = min(offset, self.fileSize)
                if clampedOffset >= self.fileSize {
                    continuation.resume(returning: Data())
                    return
                }

                do {
                    try self.fileHandle.seek(toOffset: clampedOffset)
                } catch {
                    continuation.resume(throwing: FileStreamerError.systemError(error))
                    return
                }

                let remainingBytes = self.fileSize - clampedOffset
                let clampedLength = min(length, remainingBytes)
                let data = self.fileHandle.readData(ofLength: Int(clampedLength))

                continuation.resume(returning: data)
            }
        }
    }
}
