package xyz.apollosoftware.amphitheatre

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.jupiter.api.BeforeEach
import org.mockito.Mockito
import org.mockito.Mockito.mock
import org.mockito.Mockito.times
import org.mockito.Mockito.verify
import org.mockito.stubbing.OngoingStubbing
import java.io.File
import kotlin.test.Test

/**
 * Covers the plugin's channel-facing behavior that can run on the JVM:
 * argument validation, the temporary-directory path, missing-file and
 * aliased-path rejection, and unknown-method handling. Anything that touches
 * media3 or the Android media stack needs an instrumentation test instead.
 */
internal class AmphitheatrePluginTest {
  private lateinit var plugin: AmphitheatrePlugin
  private lateinit var mockContext: Context
  private lateinit var mockBinding: FlutterPlugin.FlutterPluginBinding

  @BeforeEach
  fun prepareTests() {
    plugin = AmphitheatrePlugin()
    mockContext = mock(Context::class.java)
    mockBinding = mock(FlutterPlugin.FlutterPluginBinding::class.java)
    upon(mockBinding.applicationContext).thenReturn(mockContext)
    upon(mockBinding.binaryMessenger).thenReturn(mock(BinaryMessenger::class.java))
    plugin.onAttachedToEngine(mockBinding)
  }

  @Test
  fun handlesDetachedEngine() {
    // A plugin that was never attached (or has been detached) must answer
    // with an error rather than crashing.
    plugin = AmphitheatrePlugin()

    val call = MethodCall("getTemporaryDirectory", null)
    val mockResult: MethodChannel.Result = mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(call, mockResult)

    verify(mockResult).error(
      ErrorCodes.INIT_FAILED,
      "The plugin is not attached to an engine.",
      null,
    )
  }

  @Test
  fun getTemporaryDirectory_returnsExpectedValue() {
    val call = MethodCall("getTemporaryDirectory", null)

    upon(mockContext.cacheDir).thenReturn(File("/foo/bar/cache"))

    val mockResult: MethodChannel.Result = mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(call, mockResult)

    verify(mockResult).success("/foo/bar/cache/${kChannelName}")
  }

  @Test
  fun startExport_handlesIllegalArguments() {
    val mockResult: MethodChannel.Result = mock(MethodChannel.Result::class.java)
    fun createCall(args: Map<String, Any?>?) = MethodCall("startExport", args)

    val valid = mapOf(
      "id" to "1", "inputPath" to "/foo/in.mp4", "outputPath" to "/foo/out.mp4",
      "startMs" to 0, "endMs" to 1000, "quality" to "passthrough",
    )

    plugin.onMethodCall(createCall(null), mockResult)
    plugin.onMethodCall(createCall(valid - "id"), mockResult)
    plugin.onMethodCall(createCall(valid - "inputPath"), mockResult)
    plugin.onMethodCall(createCall(valid - "outputPath"), mockResult)
    plugin.onMethodCall(createCall(valid - "quality"), mockResult)
    // End before start.
    plugin.onMethodCall(createCall(valid + mapOf("startMs" to 1000, "endMs" to 1000)), mockResult)
    // Negative bounds.
    plugin.onMethodCall(createCall(valid + mapOf("startMs" to -1)), mockResult)

    verify(mockResult, times(7))
      .error(ErrorCodes.BAD_PARAMS, "Invalid parameters supplied to startExport()", null)

    // An unknown quality is also a parameter error (different message).
    plugin.onMethodCall(createCall(valid + mapOf("quality" to "potato")), mockResult)
    verify(mockResult).error(ErrorCodes.BAD_PARAMS, "Unknown quality: potato", null)
  }

  @Test
  fun startExport_rejectsAliasedPaths() {
    val mockResult: MethodChannel.Result = mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(
      MethodCall(
        "startExport",
        mapOf(
          "id" to "1",
          "inputPath" to "/foo/same.mp4",
          "outputPath" to "/foo/same.mp4",
          "startMs" to 0,
          "endMs" to 1000,
          "quality" to "passthrough",
        ),
      ),
      mockResult,
    )

    verify(mockResult).error(ErrorCodes.BAD_PARAMS, "The input and output paths must differ.", null)
  }

  @Test
  fun startExport_reportsMissingFile() {
    val mockResult: MethodChannel.Result = mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(
      MethodCall(
        "startExport",
        mapOf(
          "id" to "1",
          "inputPath" to "/definitely/not/a/real/file.mp4",
          "outputPath" to "/foo/out.mp4",
          "startMs" to 0,
          "endMs" to 1000,
          "quality" to "passthrough",
        ),
      ),
      mockResult,
    )

    verify(mockResult).error(ErrorCodes.NOT_FOUND, "Failed to locate the provided file.", null)
  }

  @Test
  fun cancelExport_returnsFalseForUnknownId() {
    val mockResult: MethodChannel.Result = mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(MethodCall("cancelExport", mapOf("id" to "nope")), mockResult)
    verify(mockResult).success(false)
  }

  @Test
  fun getThumbnails_handlesIllegalArguments() {
    val mockResult: MethodChannel.Result = mock(MethodChannel.Result::class.java)
    fun createCall(args: Map<String, Any?>?) = MethodCall("getThumbnails", args)

    plugin.onMethodCall(createCall(null), mockResult)
    plugin.onMethodCall(createCall(mapOf("path" to "/foo.mp4", "count" to 0, "maxHeight" to 100)), mockResult)
    plugin.onMethodCall(createCall(mapOf("path" to "/foo.mp4", "count" to 5, "maxHeight" to 0)), mockResult)

    verify(mockResult, times(3))
      .error(ErrorCodes.BAD_PARAMS, "Invalid parameters supplied to getThumbnails()", null)
  }

  @Test
  fun unknownMethod_isNotImplemented() {
    val mockResult: MethodChannel.Result = mock(MethodChannel.Result::class.java)
    plugin.onMethodCall(MethodCall("anything__thisIsNotARealAction", null), mockResult)
    verify(mockResult).notImplemented()
  }

  /** Not a fan of the backticks... See [Mockito.when] */
  private fun <T> upon(methodCall: T): OngoingStubbing<T> = Mockito.`when`(methodCall)
}
