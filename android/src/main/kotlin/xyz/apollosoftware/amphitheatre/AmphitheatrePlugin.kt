package xyz.apollosoftware.amphitheatre

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

const val kChannelName = "xyz.apollosoftware.amphitheatre"
const val kEventChannelName = "xyz.apollosoftware.amphitheatre/events"

/** Error codes shared with the Dart side (see AmphitheatreErrorCodes). */
object ErrorCodes {
  const val BAD_PARAMS = "ERR_BAD_PARAMS"
  const val NOT_FOUND = "ERR_NOT_FOUND"
  const val CANCELLED = "ERR_CANCELLED"
  const val EXPORT_FAILED = "ERR_EXPORT_FAILED"
  const val INIT_FAILED = "ERR_INIT_FAIL"
}

/**
 * AmphitheatrePlugin.
 *
 * Exports run through androidx.media3 Transformer, which performs its work on
 * background threads internally; this class only ever does lightweight
 * bookkeeping on the main thread (as required by both Transformer and
 * Flutter's platform channels). Thumbnail extraction runs on a dedicated
 * background executor.
 *
 * The plugin never deletes or modifies the input file of an export.
 */
@OptIn(UnstableApi::class)
class AmphitheatrePlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var channel: MethodChannel
  private lateinit var eventChannel: EventChannel

  private var context: Context? = null
  private var eventSink: EventChannel.EventSink? = null

  private val mainHandler = Handler(Looper.getMainLooper())
  private val thumbnailExecutor: ExecutorService = Executors.newSingleThreadExecutor()

  /** Progress polling interval, in milliseconds. */
  private val progressIntervalMs = 250L

  /** Active exports, keyed by export ID. Only accessed from the main thread. */
  private val activeExports = HashMap<String, ActiveExport>()

  private class ActiveExport(
    val transformer: Transformer,
    val result: Result,
    val outputFile: File,
  )

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, kChannelName)
    channel.setMethodCallHandler(this)
    eventChannel = EventChannel(binding.binaryMessenger, kEventChannelName)
    eventChannel.setStreamHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // The Dart side is going away: abort any in-flight exports and clean up
    // their partial output.
    for (export in activeExports.values) {
      export.transformer.cancel()
      export.outputFile.delete()
    }
    activeExports.clear()

    channel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    thumbnailExecutor.shutdown()
    eventSink = null
    context = null
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    try {
      when (call.method) {
        "getTemporaryDirectory" -> getTemporaryDirectory(result)
        "startExport" -> startExport(call, result)
        "cancelExport" -> cancelExport(call, result)
        "getThumbnails" -> getThumbnails(call, result)
        else -> result.notImplemented()
      }
    } catch (exception: Exception) {
      // Defensive: a platform method must always answer, never crash the app.
      result.error(ErrorCodes.EXPORT_FAILED, exception.message ?: exception.toString(), null)
    }
  }

  private fun getTemporaryDirectory(result: Result) {
    val context = this.context
      ?: return result.error(ErrorCodes.INIT_FAILED, "The plugin is not attached to an engine.", null)

    val cacheDir = File(context.cacheDir.absolutePath, kChannelName)
    if (!cacheDir.exists()) cacheDir.mkdirs()
    result.success(cacheDir.absolutePath)
  }

  private fun startExport(call: MethodCall, result: Result) {
    val context = this.context
      ?: return result.error(ErrorCodes.INIT_FAILED, "The plugin is not attached to an engine.", null)

    val id = call.argument<String>("id")
    val inputPath = call.argument<String>("inputPath")
    val outputPath = call.argument<String>("outputPath")
    val startMs = call.argument<Number>("startMs")?.toLong()
    val endMs = call.argument<Number>("endMs")?.toLong()
    val quality = call.argument<String>("quality")

    if (id == null || inputPath == null || outputPath == null || quality == null ||
      (startMs != null && startMs < 0) || (endMs != null && endMs < 0) ||
      (startMs != null && endMs != null && endMs <= startMs)
    ) {
      return result.error(ErrorCodes.BAD_PARAMS, "Invalid parameters supplied to startExport()", null)
    }

    val targetHeight: Int? = when (quality) {
      "passthrough" -> null
      "2160p" -> 2160
      "1080p" -> 1080
      "720p" -> 720
      else -> return result.error(ErrorCodes.BAD_PARAMS, "Unknown quality: $quality", null)
    }

    if (activeExports.containsKey(id)) {
      return result.error(ErrorCodes.BAD_PARAMS, "An export with ID '$id' is already running.", null)
    }

    val inputFile = File(inputPath)
    if (!inputFile.isFile) {
      return result.error(ErrorCodes.NOT_FOUND, "Failed to locate the provided file.", null)
    }

    val outputFile = File(outputPath)
    outputFile.parentFile?.mkdirs()

    val clippingConfiguration = MediaItem.ClippingConfiguration.Builder().apply {
      if (startMs != null) setStartPositionMs(startMs)
      if (endMs != null) setEndPositionMs(endMs)
    }.build()

    val mediaItem = MediaItem.Builder()
      .setUri(Uri.fromFile(inputFile))
      .setClippingConfiguration(clippingConfiguration)
      .build()

    val editedMediaItem = EditedMediaItem.Builder(mediaItem).apply {
      // Only scale down; never upscale a video that is already smaller than
      // the requested quality.
      if (targetHeight != null && targetHeight < displayHeightOf(inputPath)) {
        setEffects(Effects(emptyList(), listOf(Presentation.createForHeight(targetHeight))))
      }
    }.build()

    // NB: the default muxer (InAppMp4Muxer, media3 1.9+) already attempts
    // streamable fast-start MP4 output, so no muxer configuration is needed.
    val transformer = Transformer.Builder(context)
      .apply {
        if (targetHeight != null) {
          // Transcode to broadly compatible codecs at the requested size.
          setVideoMimeType(MimeTypes.VIDEO_H264)
          setAudioMimeType(MimeTypes.AUDIO_AAC)
        } else {
          // Pure trim: stream-copy everything except (at most) the first GOP,
          // which keeps trims fast, lossless, and accurate.
          experimentalSetTrimOptimizationEnabled(true)
        }
      }
      .addListener(object : Transformer.Listener {
        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
          finishExport(id) { export -> export.result.success(export.outputFile.absolutePath) }
        }

        override fun onError(
          composition: Composition,
          exportResult: ExportResult,
          exportException: ExportException,
        ) {
          finishExport(id) { export ->
            export.outputFile.delete()
            export.result.error(
              ErrorCodes.EXPORT_FAILED,
              exportException.message ?: "The export failed.",
              "media3 error code: ${exportException.errorCode}",
            )
          }
        }
      })
      .build()

    try {
      transformer.start(editedMediaItem, outputFile.absolutePath)
    } catch (exception: Exception) {
      outputFile.delete()
      return result.error(
        ErrorCodes.EXPORT_FAILED,
        exception.message ?: "The export could not be started.",
        null,
      )
    }

    // Registering after start() is safe: listener callbacks are posted to
    // this (the main) thread's looper, so they cannot run until this method
    // returns.
    activeExports[id] = ActiveExport(transformer, result, outputFile)
    scheduleProgressUpdates(id)
  }

  /**
   * Returns the height of the video at [path] in display orientation, or
   * [Int.MAX_VALUE] if it cannot be determined (in which case scaling is
   * skipped and the encoder receives the source size).
   */
  private fun displayHeightOf(path: String): Int {
    val retriever = MediaMetadataRetriever()
    return try {
      retriever.setDataSource(path)
      val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
      val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
      val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0

      if (width == null || height == null) Int.MAX_VALUE
      else if (rotation == 90 || rotation == 270) width
      else height
    } catch (_: Exception) {
      Int.MAX_VALUE
    } finally {
      try {
        retriever.release()
      } catch (_: Exception) {
        // Releasing best-effort; the retriever is not reused.
      }
    }
  }

  private fun scheduleProgressUpdates(id: String) {
    val progressHolder = ProgressHolder()

    val poll = object : Runnable {
      override fun run() {
        // Stops automatically once the export is no longer active.
        val export = activeExports[id] ?: return

        if (export.transformer.getProgress(progressHolder) == Transformer.PROGRESS_STATE_AVAILABLE) {
          eventSink?.success(mapOf("id" to id, "progress" to progressHolder.progress / 100.0))
        }

        mainHandler.postDelayed(this, progressIntervalMs)
      }
    }

    mainHandler.post(poll)
  }

  private fun cancelExport(call: MethodCall, result: Result) {
    val id = call.argument<String>("id")
      ?: return result.error(ErrorCodes.BAD_PARAMS, "Invalid parameters supplied to cancelExport()", null)

    val export = activeExports.remove(id)
    if (export == null) {
      result.success(false)
      return
    }

    export.transformer.cancel()
    export.outputFile.delete()
    export.result.error(ErrorCodes.CANCELLED, "The export was cancelled.", null)
    result.success(true)
  }

  /** Completes and removes the export with the given [id], if still active. */
  private fun finishExport(id: String, complete: (ActiveExport) -> Unit) {
    val export = activeExports.remove(id) ?: return
    complete(export)
  }

  private fun getThumbnails(call: MethodCall, result: Result) {
    val path = call.argument<String>("path")
    val count = call.argument<Number>("count")?.toInt()
    val maxHeight = call.argument<Number>("maxHeight")?.toInt()

    if (path == null || count == null || maxHeight == null || count < 1 || maxHeight < 1) {
      return result.error(ErrorCodes.BAD_PARAMS, "Invalid parameters supplied to getThumbnails()", null)
    }

    if (!File(path).isFile) {
      return result.error(ErrorCodes.NOT_FOUND, "Failed to locate the provided file.", null)
    }

    val boundedCount = count.coerceAtMost(50)
    val boundedMaxHeight = maxHeight.coerceAtMost(1080)

    thumbnailExecutor.execute {
      val thumbnails = extractThumbnails(path, boundedCount, boundedMaxHeight)
      mainHandler.post { result.success(thumbnails) }
    }
  }

  /**
   * Extracts up to [count] JPEG thumbnails, evenly spaced across the video
   * (at the midpoint of each cell so first/last frames are representative).
   *
   * Failures on individual frames are skipped; a failure to read the video at
   * all yields an empty list. The Dart side treats thumbnails as a
   * progressive enhancement, so this never reports an error.
   */
  private fun extractThumbnails(path: String, count: Int, maxHeight: Int): List<ByteArray> {
    val thumbnails = ArrayList<ByteArray>(count)
    val retriever = MediaMetadataRetriever()

    try {
      retriever.setDataSource(path)
      val durationMs =
        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: return thumbnails

      for (i in 0 until count) {
        val timeUs = (durationMs * 1000L * (2L * i + 1)) / (2L * count)

        var bitmap = frameAt(retriever, timeUs, maxHeight) ?: continue
        if (bitmap.height > maxHeight) {
          val scaledWidth = bitmap.width * maxHeight / bitmap.height
          val scaled = Bitmap.createScaledBitmap(bitmap, scaledWidth.coerceAtLeast(1), maxHeight, true)
          bitmap.recycle()
          bitmap = scaled
        }

        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 70, stream)
        bitmap.recycle()
        thumbnails.add(stream.toByteArray())
      }
    } catch (_: Exception) {
      // Return whatever was extracted successfully.
    } finally {
      try {
        retriever.release()
      } catch (_: Exception) {
        // Releasing best-effort; the retriever is not reused.
      }
    }

    return thumbnails
  }

  private fun frameAt(retriever: MediaMetadataRetriever, timeUs: Long, maxHeight: Int): Bitmap? {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
      val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
      val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()

      if (height != null && width != null && height > maxHeight) {
        val scaledWidth = (width * maxHeight / height).coerceAtLeast(1)
        return retriever.getScaledFrameAtTime(
          timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, scaledWidth, maxHeight,
        )
      }
    }

    return retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
  }
}
