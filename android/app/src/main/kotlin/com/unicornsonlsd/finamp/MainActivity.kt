package com.unicornsonlsd.finamp

import android.app.UiModeManager
import android.content.Intent
import android.content.Intent.CATEGORY_APP_MUSIC
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore.INTENT_ACTION_MUSIC_PLAYER
import android.provider.Settings
import android.system.ErrnoException
import android.system.Os
import android.util.Log
import androidx.annotation.WorkerThread
import androidx.core.net.toUri
import androidx.lifecycle.lifecycleScope
import androidx.mediarouter.app.SystemOutputSwitcherDialogController
import androidx.mediarouter.media.MediaRouter
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.unicornsonlsd.finamp.automix.AutoMixAnalyzer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.File
import java.security.KeyStore
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext


class MainActivity : AudioServiceActivity() {
    companion object {
        private const val CLIENT_CERT_CHANNEL = "com.unicornsonlsd.finamp/client_certificate"
        private const val CLIENT_CERT_CHANNEL_LOG_TAG = "ClientCertChannel"

        private const val DOWNLOADS_SERVICE_CHANNEL = "com.unicornsonlsd.finamp/downloads_service"
        private const val DOWNLOADS_SERVICE_CHANNEL_LOG_TAG = "DownloadsServiceChannel"

        private const val OUTPUT_SWITCHER_CHANNEL = "com.unicornsonlsd.finamp/output_switcher"
        private const val OUTPUT_SWITCHER_CHANNEL_LOG_TAG = "OutputSwitcherChannel"

        private const val SET_NATIVE_THEME_CHANNEL = "com.unicornsonlsd.finamp/set_native_theme"
        private const val SET_NATIVE_THEME_CHANNEL_LOG_TAG = "setNativeThemeChannel"

        private const val AUTOMIX_CHANNEL = "com.unicornsonlsd.finamp/automix_analyzer"

        // Not tied to the activity lifecycle: analysis must keep running while the app plays in background.
        private val automixScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        private val automixLimiter = Semaphore(1)
    }

    private lateinit var mediaRouter: MediaRouter

    override fun onCreate(savedInstanceState: Bundle?) {
        updateIntent(intent)
        super.onCreate(savedInstanceState)

        mediaRouter = MediaRouter.getInstance(this)
    }

    override fun onNewIntent(intent: Intent) {
        updateIntent(intent)
        super.onNewIntent(intent)
    }

    private fun updateIntent(intent: Intent) {
        if (
            (intent.action == INTENT_ACTION_MUSIC_PLAYER || intent.action == CATEGORY_APP_MUSIC) &&
            intent.data == null
        ) {
            intent.data = "finamp://play/surprisemix".toUri()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CLIENT_CERT_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installClientCertificate" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val password = call.argument<String>("password")
                    if (bytes == null || password == null) {
                        result.error("INVALID_ARGS", "bytes and password are required", null)
                        return@setMethodCallHandler
                    }
                    lifecycleScope.launch {
                        withContext(Dispatchers.IO) {
                            try {
                                installClientCertificate(bytes, password)

                                Log.i(
                                    CLIENT_CERT_CHANNEL_LOG_TAG,
                                    "Client certificate installed in Android SSL context"
                                )
                                result.success(null)
                            } catch (e: Exception) {
                                Log.e(
                                    CLIENT_CERT_CHANNEL_LOG_TAG,
                                    "Failed to install client certificate",
                                    e
                                )
                                result.error("CERT_ERROR", e.message, null)
                            }
                        }
                    }
                }
                "clearClientCertificate" -> {
                    lifecycleScope.launch {
                        withContext(Dispatchers.IO) {
                            try {
                                clearClientCertificate()

                                Log.i(
                                    CLIENT_CERT_CHANNEL_LOG_TAG,
                                    "Client certificate cleared from Android SSL context"
                                )
                                result.success(null)
                            } catch (e: Exception) {
                                Log.e(CLIENT_CERT_CHANNEL_LOG_TAG, "Failed to clear client certificate", e)
                                result.error("CERT_ERROR", e.message, null)
                            }
                        }
                    }
                }
                else -> {
                    Log.e(CLIENT_CERT_CHANNEL_LOG_TAG, "Method not found: '${call.method}'")
                    result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOWNLOADS_SERVICE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "fixDownloadsFileOwner" -> {
                    val downloadLocations = call.argument<List<String>?>("download_locations").orEmpty()
                    lifecycleScope.launch {
                        withContext(Dispatchers.IO) {
                            fixDownloadsFileOwner(downloadLocations)
                        }
                    }
                    result.success(null)
                }
                else -> {
                    Log.e(DOWNLOADS_SERVICE_CHANNEL_LOG_TAG, "Method not found: '${call.method}'")
                    result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SET_NATIVE_THEME_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setNativeThemeMode" -> {
                    val uiManager: UiModeManager =
                        applicationContext.getSystemService(UI_MODE_SERVICE) as UiModeManager

                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                        // Only api >= 31 supports uiManager.setApplicationNightMode
                        // There might be a way to set this on older versions of android, but
                        // I don't feel like debugging that at the moment
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val targetMode = call.argument<Int?>("targetMode")
                    when (targetMode) {
                        0 -> {
                            uiManager.setApplicationNightMode(UiModeManager.MODE_NIGHT_AUTO)
                            result.success(null)
                        }
                        1 -> {
                            uiManager.setApplicationNightMode(UiModeManager.MODE_NIGHT_NO)
                            result.success(null)
                        }
                        2 -> {
                            uiManager.setApplicationNightMode(UiModeManager.MODE_NIGHT_YES)
                            result.success(null)
                        }
                        else -> {
                            Log.e(SET_NATIVE_THEME_CHANNEL_LOG_TAG, "Method not found: '${call.method}'")
                            result.notImplemented()
                        }
                    }
                }
                else -> {
                    Log.e(SET_NATIVE_THEME_CHANNEL_LOG_TAG, "Method not found: '${call.method}'")
                    result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUTOMIX_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "analyze" -> {
                    val uri = call.argument<String>("uri")
                    val headMs = (call.argument<Number>("headMs") ?: 30000).toLong()
                    val tailMs = (call.argument<Number>("tailMs") ?: 45000).toLong()
                    val durationMs = (call.argument<Number>("durationMs") ?: -1).toLong()
                    if (uri == null) {
                        result.error("INVALID_ARGUMENT", "uri is required", null)
                    } else {
                        automixScope.launch {
                            var failure: String? = null
                            val analysis = try {
                                automixLimiter.withPermit {
                                    // a stuck native call must not block the following analyses
                                    val job = automixScope.async(Dispatchers.IO) {
                                        AutoMixAnalyzer.analyze(uri, headMs, tailMs, applicationContext.cacheDir, durationMs)
                                    }
                                    withTimeoutOrNull(75_000) { job.await() }
                                        ?: throw IllegalStateException("analyse bloquée à l'étape : ${AutoMixAnalyzer.progress}")
                                }
                            } catch (e: Throwable) {
                                Log.w("AutoMixAnalyzer", "analysis failed", e)
                                failure = "${e.javaClass.simpleName}: ${e.message}"
                                null
                            }
                            withContext(Dispatchers.Main) {
                                if (analysis != null) result.success(analysis)
                                else result.error("ANALYSIS_FAILED", failure, null)
                            }
                        }
                    }
                }
                "progress" -> result.success(AutoMixAnalyzer.progress)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OUTPUT_SWITCHER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            Log.d(OUTPUT_SWITCHER_CHANNEL_LOG_TAG, "Calling method: '${call.method}'")
            when (call.method) {
                "showOutputSwitcherDialog" -> {
                    showOutputSwitcherDialog()
                    result.success(null)
                }
                "getRoutes" -> {
                    val routes = mediaRouter.routes
                    routes.log()
                    result.success(routes.map { route ->
                        mapOf(
                            "name" to route.name,
                            "connectionState" to route.connectionState,
                            "isSystemRoute" to route.isSystemRoute,
                            "isDefault" to route.isDefault,
                            "isDeviceSpeaker" to route.isDeviceSpeaker,
                            "isBluetooth" to route.isBluetooth,
                            "volume" to route.volume,
                            "providerPackageName" to route.provider.packageName,
                            "isSelected" to route.isSelected,
                            "deviceType" to route.deviceType,
                            "description" to route.description,
                            "extras" to route.extras,
                            "iconUri" to route.iconUri,
                            // "controlFilters" to route.controlFilters,
                        )
                    })
                }
                "setOutputToDeviceSpeaker" -> {
                    val routes = mediaRouter.routes
                    routes.log()
                    val deviceSpeakerRoute = routes.first { route -> route.isDeviceSpeaker }
                    mediaRouter.selectRoute(deviceSpeakerRoute)
                    result.success(null)
                }
                "setOutputToBluetoothDevice" -> {
                    val routes = mediaRouter.routes
                    routes.log()
                    val bluetoothRoute = routes.first { route -> route.isBluetooth }
                    mediaRouter.selectRoute(bluetoothRoute)
                    result.success(null)
                }
                "setOutputToRouteByName" -> {
                    val routes = mediaRouter.routes
                    routes.log()
                    val targetRoute = routes.first { route ->
                        route.name == call.argument<String>("name")
                    }
                    mediaRouter.selectRoute(targetRoute)
                    result.success(null)
                }
                "openBluetoothSettings" -> {
                    startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                    result.success(null)
                }
                else -> {
                    Log.e(OUTPUT_SWITCHER_CHANNEL_LOG_TAG, "Method not found: '${call.method}'")
                    result.notImplemented()
                }
            }
        }
    }

    private fun installClientCertificate(bytes: ByteArray, password: String) {
        val keyStore = KeyStore.getInstance("PKCS12")
        keyStore.load(ByteArrayInputStream(bytes), password.toCharArray())

        val keyManagerFactory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        keyManagerFactory.init(keyStore, password.toCharArray())

        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(keyManagerFactory.keyManagers, null, null)

        SSLContext.setDefault(sslContext)
        HttpsURLConnection.setDefaultSSLSocketFactory(sslContext.socketFactory)
    }

    private fun clearClientCertificate() {
        val defaultContext = SSLContext.getInstance("TLS")
        defaultContext.init(null, null, null)
        SSLContext.setDefault(defaultContext)
        HttpsURLConnection.setDefaultSSLSocketFactory(defaultContext.socketFactory)
    }

    /**
     * Fixes the owner of downloaded files.
     *
     * Originally, files downloaded by the app were set to a special "cache" user group,
     * which caused the system to count all downloads as cache files.
     * Manually setting the group to the app's UID (which is equal to the gid) fixes this behavior for past downloads.
     */
    @WorkerThread
    private fun fixDownloadsFileOwner(downloadLocations: List<String>) {
        val appUid = applicationInfo.uid
        val cacheGid = try {
            Os.stat(context.cacheDir.absolutePath).st_gid
        } catch (e: ErrnoException) {
            Log.e(DOWNLOADS_SERVICE_CHANNEL_LOG_TAG, "Failed to get cache directory GID", e)
            return
        }
        for (downloadLocation in downloadLocations) {
            val downloadDirectory = File(downloadLocation)
            if (!downloadDirectory.isDirectory) {
                Log.w(DOWNLOADS_SERVICE_CHANNEL_LOG_TAG, "Download location is not a directory: $downloadLocation")
                continue
            }

            for (file in downloadDirectory.walkTopDown()) {
                try {
                    if (!file.isFile) continue

                    // Skip files not owned by the cache group
                    val gid = Os.stat(file.absolutePath).st_gid
                    if (gid != cacheGid) continue

                    Os.chown(file.absolutePath, -1, appUid) // uid -1 keeps current owner
                } catch (e: ErrnoException) {
                    Log.e(DOWNLOADS_SERVICE_CHANNEL_LOG_TAG, "Failed to fix owner for: ${file.absolutePath}", e)
                }
            }
        }
    }

    private fun List<MediaRouter.RouteInfo>.log() {
        forEach { route ->
            Log.d(
                OUTPUT_SWITCHER_CHANNEL_LOG_TAG,
                "Route: ${route.name}, connection state: ${route.connectionState}, system route: ${route.isSystemRoute}, default: ${route.isDefault}, device speaker: ${route.isDeviceSpeaker}, bluetooth: ${route.isBluetooth}, volume: ${route.volume}, provider: ${route.provider.packageName}"
            )
        }
    }

    private fun showOutputSwitcherDialog() {
        SystemOutputSwitcherDialogController.showDialog(this)
    }
}
