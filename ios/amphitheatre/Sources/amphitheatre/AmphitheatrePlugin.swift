import Flutter
import UIKit
import AVFoundation

let PLUGIN_BUNDLE_ID = "xyz.apollosoftware.amphitheatre"
let PLUGIN_EVENT_CHANNEL = "xyz.apollosoftware.amphitheatre/events"

/// Error codes shared with the Dart side (see AmphitheatreErrorCodes).
enum ErrorCodes {
    static let badParams = "ERR_BAD_PARAMS"
    static let notFound = "ERR_NOT_FOUND"
    static let cancelled = "ERR_CANCELLED"
    static let exportFailed = "ERR_EXPORT_FAILED"
    static let initFailed = "ERR_INIT_FAIL"
}

/// AmphitheatrePlugin.
///
/// Exports run through AVAssetExportSession, which performs its work off the
/// main thread internally. All Flutter callbacks (`FlutterResult` and
/// `FlutterEventSink`) are dispatched on the main thread, as required by the
/// Flutter engine. The plugin never deletes or modifies the input file of an
/// export.
public class AmphitheatrePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    /// Active exports keyed by export ID. Only accessed on the main thread.
    private var activeExports: [String: ActiveExport] = [:]

    private final class ActiveExport {
        let session: AVAssetExportSession
        var task: Task<Void, Never>?
        var cancelled = false

        init(session: AVAssetExportSession) {
            self.session = session
        }
    }

    @objc
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = AmphitheatrePlugin()

        let channel = FlutterMethodChannel(name: PLUGIN_BUNDLE_ID, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)

        let eventChannel = FlutterEventChannel(name: PLUGIN_EVENT_CHANNEL, binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    @objc
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getTemporaryDirectory":
            getTemporaryDirectory(result: result)
        case "startExport":
            startExport(call, result: result)
        case "cancelExport":
            cancelExport(call, result: result)
        case "getThumbnails":
            getThumbnails(call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - getTemporaryDirectory

    private func getTemporaryDirectory(result: @escaping FlutterResult) {
        let cachesDirectory = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)

        guard let base = cachesDirectory.first else {
            result(FlutterError(code: ErrorCodes.initFailed, message: "Failed to locate the user temporary directory.", details: nil))
            return
        }

        let url = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(PLUGIN_BUNDLE_ID)
        let path = url.path

        if !FileManager.default.fileExists(atPath: path) {
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) == nil {
                result(FlutterError(code: ErrorCodes.initFailed, message: "Failed to create the package-specific temporary directory.", details: nil))
                return
            }
        }

        result(path)
    }

    // MARK: - startExport

    private func startExport(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let id = args["id"] as? String,
              let inputPath = args["inputPath"] as? String,
              let outputPath = args["outputPath"] as? String,
              let quality = args["quality"] as? String
        else {
            result(FlutterError(code: ErrorCodes.badParams, message: "Invalid parameters supplied to startExport()", details: nil))
            return
        }

        let startMs = (args["startMs"] as? NSNumber)?.int64Value
        let endMs = (args["endMs"] as? NSNumber)?.int64Value

        if let startMs, startMs < 0 { return reportBadParams(result) }
        if let endMs, endMs < 0 { return reportBadParams(result) }
        if let startMs, let endMs, endMs <= startMs { return reportBadParams(result) }

        // The input file is never modified or deleted; the pre-export cleanup
        // and failure paths delete the output file, so the two must never
        // alias.
        guard URL(fileURLWithPath: inputPath).standardizedFileURL
                != URL(fileURLWithPath: outputPath).standardizedFileURL else {
            result(FlutterError(code: ErrorCodes.badParams, message: "The input and output paths must differ.", details: nil))
            return
        }

        guard activeExports[id] == nil else {
            result(FlutterError(code: ErrorCodes.badParams, message: "An export with ID '\(id)' is already running.", details: nil))
            return
        }

        let preset: String
        switch quality {
        case "passthrough": preset = AVAssetExportPresetPassthrough
        case "2160p": preset = AVAssetExportPreset3840x2160
        case "1080p": preset = AVAssetExportPreset1920x1080
        case "720p": preset = AVAssetExportPreset1280x720
        default:
            result(FlutterError(code: ErrorCodes.badParams, message: "Unknown quality: \(quality)", details: nil))
            return
        }

        guard FileManager.default.fileExists(atPath: inputPath) else {
            result(FlutterError(code: ErrorCodes.notFound, message: "Failed to locate the provided file.", details: nil))
            return
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            result(FlutterError(code: ErrorCodes.initFailed, message: "The requested export preset is not supported on this device.", details: nil))
            return
        }

        // Fast-start (moov atom at the front) for CDN/streaming friendliness.
        session.shouldOptimizeForNetworkUse = true

        if startMs != nil || endMs != nil {
            let start = CMTime(value: CMTimeValue(startMs ?? 0), timescale: 1000)
            let end = endMs.map { CMTime(value: CMTimeValue($0), timescale: 1000) } ?? .positiveInfinity
            session.timeRange = CMTimeRange(start: start, end: end)
        }

        let outUrl = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(
            at: outUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outUrl)

        let export = ActiveExport(session: session)
        activeExports[id] = export

        export.task = Task {
            await self.runExport(id: id, session: session, to: outUrl, result: result)
        }
    }

    private func reportBadParams(_ result: @escaping FlutterResult) {
        result(FlutterError(code: ErrorCodes.badParams, message: "Invalid parameters supplied to startExport()", details: nil))
    }

    private func runExport(
        id: String,
        session: AVAssetExportSession,
        to outUrl: URL,
        result: @escaping FlutterResult
    ) async {
        let progressTask = observeProgress(id: id, session: session)
        defer { progressTask.cancel() }

        var failure: Error? = nil

        if #available(iOS 18, *) {
            do {
                try await session.export(to: outUrl, as: .mp4)
            } catch {
                failure = error
            }
        } else {
            session.outputURL = outUrl
            session.outputFileType = .mp4
            await session.export()

            switch session.status {
            case .completed:
                failure = nil
            case .cancelled:
                // The cancelled flag drives the ERR_CANCELLED response below.
                failure = CancellationError()
            default:
                failure = session.error ?? NSError(
                    domain: PLUGIN_BUNDLE_ID, code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The export ended in an illegal state."])
            }
        }

        let finalFailure = failure
        await MainActor.run {
            self.completeExport(id: id, outUrl: outUrl, failure: finalFailure, result: result)
        }
    }

    /// Streams progress events for the export to the Dart side while it runs.
    private func observeProgress(id: String, session: AVAssetExportSession) -> Task<Void, Never> {
        if #available(iOS 18, *) {
            return Task {
                for await state in session.states(updateInterval: 0.25) {
                    if case .exporting(let progress) = state {
                        let fraction = progress.fractionCompleted
                        await MainActor.run { self.eventSink?(["id": id, "progress": fraction]) }
                    }
                }
            }
        }

        return Task {
            while !Task.isCancelled {
                let progress = Double(session.progress)
                await MainActor.run { self.eventSink?(["id": id, "progress": progress]) }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Completes the export on the main thread, answering the pending Flutter
    /// result exactly once and cleaning up partial output on failure.
    private func completeExport(id: String, outUrl: URL, failure: Error?, result: @escaping FlutterResult) {
        guard let export = activeExports.removeValue(forKey: id) else { return }

        if export.cancelled || failure is CancellationError {
            try? FileManager.default.removeItem(at: outUrl)
            result(FlutterError(code: ErrorCodes.cancelled, message: "The export was cancelled.", details: nil))
        } else if let failure {
            try? FileManager.default.removeItem(at: outUrl)
            result(FlutterError(
                code: ErrorCodes.exportFailed,
                message: failure.localizedDescription,
                details: String(describing: failure)))
        } else {
            result(outUrl.path)
        }
    }

    // MARK: - cancelExport

    private func cancelExport(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let id = args["id"] as? String
        else {
            result(FlutterError(code: ErrorCodes.badParams, message: "Invalid parameters supplied to cancelExport()", details: nil))
            return
        }

        guard let export = activeExports[id] else {
            result(false)
            return
        }

        export.cancelled = true
        if #available(iOS 18, *) {
            // The modern export API aborts when its task is cancelled.
            export.task?.cancel()
        } else {
            export.session.cancelExport()
        }

        result(true)
    }

    // MARK: - getThumbnails

    private func getThumbnails(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String,
              let count = (args["count"] as? NSNumber)?.intValue,
              let maxHeight = (args["maxHeight"] as? NSNumber)?.intValue,
              count >= 1, maxHeight >= 1
        else {
            result(FlutterError(code: ErrorCodes.badParams, message: "Invalid parameters supplied to getThumbnails()", details: nil))
            return
        }

        guard FileManager.default.fileExists(atPath: path) else {
            result(FlutterError(code: ErrorCodes.notFound, message: "Failed to locate the provided file.", details: nil))
            return
        }

        let boundedCount = min(count, 50)
        let boundedHeight = min(maxHeight, 1080)

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: CGFloat(boundedHeight))

        // Thumbnails are a progressive enhancement: individual frame failures
        // are skipped and a total failure returns an empty list, never an
        // error.
        Task.detached(priority: .utility) {
            let duration: CMTime
            if #available(iOS 15, *) {
                duration = (try? await asset.load(.duration)) ?? .zero
            } else {
                duration = asset.duration
            }

            let seconds = CMTimeGetSeconds(duration)

            // An unreadable or indefinite duration (corrupt file, stream)
            // would produce invalid CMTimes; return no thumbnails instead.
            guard seconds.isFinite, seconds > 0 else {
                await MainActor.run { result([FlutterStandardTypedData]()) }
                return
            }

            let times: [CMTime] = (0..<boundedCount).map { index in
                CMTime(
                    seconds: seconds * (2.0 * Double(index) + 1.0) / (2.0 * Double(boundedCount)),
                    preferredTimescale: 600)
            }

            var thumbnails: [FlutterStandardTypedData] = []

            if #available(iOS 16, *) {
                for await imageResult in generator.images(for: times) {
                    if let cgImage = try? imageResult.image,
                       let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7) {
                        thumbnails.append(FlutterStandardTypedData(bytes: jpeg))
                    }
                }
            } else {
                for time in times {
                    if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil),
                       let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7) {
                        thumbnails.append(FlutterStandardTypedData(bytes: jpeg))
                    }
                }
            }

            let collected = thumbnails
            await MainActor.run { result(collected) }
        }
    }
}
