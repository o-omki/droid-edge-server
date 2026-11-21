package com.example.droid_edge_server

import android.app.ActivityManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.SamplerConfig
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * Native Android bridge for Tier 3 on-device LiteRT-LM (`.litertlm`) inference
 * and zero-download local model file import via Storage Access Framework.
 *
 * All heavy engine initialisation, model loading, and inference calls run off
 * the main thread on a serialised single-thread executor to prevent concurrent
 * multi-gigabyte allocations or GPU context races.
 */
class LiteRtLmBridge(private val context: Context) {
    companion object {
        const val CHANNEL_NAME = "com.example.droid_edge_server/litert_lm"
        const val MIN_DEVICE_RAM_GB = 5.5
        private const val MAX_NUM_TOKENS = 2048
        private const val COPY_BUFFER_BYTES = 1024 * 1024
    }

    private val appContext: Context = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val inferenceExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private var engine: Engine? = null
    private var loadedModelPath: String? = null

    @Volatile
    private var activeConversation: Conversation? = null

    /**
     * Returns total physical device RAM in gigabytes rounded to one decimal place.
     */
    fun getDeviceRamGb(): Double? {
        return try {
            val activityManager =
                appContext.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                    ?: return null
            val memoryInfo = ActivityManager.MemoryInfo()
            activityManager.getMemoryInfo(memoryInfo)
            if (memoryInfo.totalMem <= 0L) {
                return null
            }
            val gb = memoryInfo.totalMem.toDouble() / (1024.0 * 1024.0 * 1024.0)
            (gb * 10.0).roundToInt() / 10.0
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Returns the dedicated app-owned directory where sideloaded or imported
     * `.litertlm` model files are stored.
     */
    fun getModelsDirectory(): String {
        val dir = appContext.getExternalFilesDir("models") ?: File(appContext.filesDir, "models")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir.absolutePath
    }

    /**
     * Lazily loads the `.litertlm` model from [modelPath] (if not already cached),
     * executes a single-turn inference request, and invokes [onSuccess] or [onError]
     * on the Android main thread.
     */
    fun runInference(
        prompt: String,
        modelPath: String,
        forceJson: Boolean,
        onSuccess: (String) -> Unit,
        onError: (code: String, message: String) -> Unit,
    ) {
        inferenceExecutor.execute {
            try {
                val modelFile = File(modelPath)
                if (!modelPath.lowercase(Locale.ROOT).endsWith(".litertlm")) {
                    postError(onError, "LITERT_INVALID_MODEL", "Model file must have a .litertlm extension.")
                    return@execute
                }
                if (!modelFile.exists() || !modelFile.isFile || modelFile.length() <= 0L || !modelFile.canRead()) {
                    postError(onError, "LITERT_MODEL_MISSING", "Model file is missing or unreadable: $modelPath")
                    return@execute
                }

                val ramGb = getDeviceRamGb()
                if (ramGb != null && ramGb < MIN_DEVICE_RAM_GB) {
                    postError(
                        onError,
                        "LITERT_LOW_RAM",
                        "Tier 3 LiteRT-LM requires at least $MIN_DEVICE_RAM_GB GB RAM (detected $ramGb GB).",
                    )
                    return@execute
                }

                val activeEngine = ensureEngineLoaded(modelFile.absolutePath)
                val conversationConfig = ConversationConfig(
                    samplerConfig = SamplerConfig(
                        topK = 40,
                        topP = 0.95,
                        temperature = if (forceJson) 0.1 else 0.3,
                    ),
                )

                val conversation = activeEngine.createConversation(conversationConfig)
                activeConversation = conversation
                try {
                    val response = conversation.sendMessage(prompt)
                    val text = response.contents.contents
                        .filterIsInstance<Content.Text>()
                        .joinToString("") { it.text }
                        .ifEmpty { response.toString() }
                        .trim()
                    mainHandler.post { onSuccess(text) }
                } finally {
                    activeConversation = null
                    try {
                        conversation.close()
                    } catch (_: Throwable) {
                    }
                }
            } catch (oom: OutOfMemoryError) {
                closeEngineInternal()
                postError(onError, "LITERT_OOM", oom.message ?: "Out of memory during LiteRT-LM inference.")
            } catch (error: Throwable) {
                postError(onError, "LITERT_ERROR", error.message ?: error.javaClass.simpleName)
            }
        }
    }

    /**
     * Requests cancellation of any in-flight conversation turn.
     */
    fun cancelInference() {
        val conversation = activeConversation ?: return
        try {
            conversation.cancelProcess()
        } catch (_: Throwable) {
        }
    }

    /**
     * Cancels active generation and releases the loaded native [Engine] handle
     * on the worker executor, then invokes [onComplete] on the main thread.
     */
    fun unloadModel(onComplete: () -> Unit) {
        cancelInference()
        inferenceExecutor.execute {
            closeEngineInternal()
            mainHandler.post(onComplete)
        }
    }

    /**
     * Imports a user-selected `.litertlm` document [uri] off the UI thread.
     *
     * Attempts zero-copy resolution for directly readable primary external
     * storage files; otherwise streams the file with a 1 MB buffer into
     * [getModelsDirectory].
     */
    fun importModelUri(
        uri: Uri,
        onSuccess: (String) -> Unit,
        onError: (code: String, message: String) -> Unit,
    ) {
        ioExecutor.execute {
            try {
                val rawName = resolveDisplayName(uri) ?: "model.litertlm"
                if (!rawName.lowercase(Locale.ROOT).endsWith(".litertlm")) {
                    postError(
                        onError,
                        "INVALID_MODEL_EXTENSION",
                        "Please select a valid .litertlm model file (selected: $rawName).",
                    )
                    return@execute
                }

                val directPath = tryResolveDirectReadablePath(uri)
                if (directPath != null && directPath.lowercase(Locale.ROOT).endsWith(".litertlm")) {
                    mainHandler.post { onSuccess(directPath) }
                    return@execute
                }

                val safeName = sanitiseModelFileName(rawName)
                val modelsDir = File(getModelsDirectory())
                val targetFile = File(modelsDir, safeName)
                val partFile = File(modelsDir, "$safeName.part")
                if (partFile.exists()) {
                    partFile.delete()
                }

                val inputStream = appContext.contentResolver.openInputStream(uri)
                if (inputStream == null) {
                    postError(onError, "MODEL_UNREADABLE", "Unable to open selected model file.")
                    return@execute
                }

                try {
                    inputStream.use { input ->
                        FileOutputStream(partFile).use { output ->
                            val buffer = ByteArray(COPY_BUFFER_BYTES)
                            while (true) {
                                val read = input.read(buffer)
                                if (read <= 0) break
                                output.write(buffer, 0, read)
                            }
                            output.flush()
                        }
                    }

                    if (targetFile.exists()) {
                        targetFile.delete()
                    }
                    if (!partFile.renameTo(targetFile)) {
                        partFile.copyTo(targetFile, overwrite = true)
                        partFile.delete()
                    }
                    mainHandler.post { onSuccess(targetFile.absolutePath) }
                } catch (error: Throwable) {
                    partFile.delete()
                    throw error
                }
            } catch (error: Throwable) {
                postError(
                    onError,
                    "MODEL_IMPORT_FAILED",
                    error.message ?: "Failed to import .litertlm model file.",
                )
            }
        }
    }

    /**
     * Releases native resources and stops background executors when the
     * hosting Activity is destroyed.
     */
    fun dispose() {
        cancelInference()
        closeEngineInternal()
        inferenceExecutor.shutdownNow()
        ioExecutor.shutdownNow()
    }

    private fun ensureEngineLoaded(modelPath: String): Engine {
        val existing = engine
        if (existing != null && loadedModelPath == modelPath) {
            return existing
        }

        closeEngineInternal()

        val cachePath = appContext.cacheDir.absolutePath
        val gpuEngine = tryInitEngine(
            EngineConfig(
                modelPath = modelPath,
                backend = Backend.GPU(),
                maxNumTokens = MAX_NUM_TOKENS,
                cacheDir = cachePath,
            ),
        )
        val resolved = gpuEngine ?: initEngineOrThrow(
            EngineConfig(
                modelPath = modelPath,
                backend = Backend.CPU(),
                maxNumTokens = MAX_NUM_TOKENS,
                cacheDir = cachePath,
            ),
        )

        engine = resolved
        loadedModelPath = modelPath
        return resolved
    }

    private fun tryInitEngine(config: EngineConfig): Engine? {
        val candidate = Engine(config)
        return try {
            candidate.initialize()
            candidate
        } catch (_: Throwable) {
            try {
                candidate.close()
            } catch (_: Throwable) {
            }
            null
        }
    }

    private fun initEngineOrThrow(config: EngineConfig): Engine {
        val candidate = Engine(config)
        return try {
            candidate.initialize()
            candidate
        } catch (error: Throwable) {
            try {
                candidate.close()
            } catch (_: Throwable) {
            }
            throw error
        }
    }

    private fun closeEngineInternal() {
        val current = engine
        engine = null
        loadedModelPath = null
        if (current != null) {
            try {
                current.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun resolveDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") {
            return uri.path?.let { File(it).name }
        }
        try {
            appContext.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        val name = cursor.getString(idx)
                        if (!name.isNullOrBlank()) {
                            return name.trim()
                        }
                    }
                }
            }
        } catch (_: Throwable) {
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun tryResolveDirectReadablePath(uri: Uri): String? {
        if (uri.scheme == "file") {
            val file = uri.path?.let { File(it) }
            if (file != null && file.exists() && file.isFile && file.canRead()) {
                return file.absolutePath
            }
        }
        if (DocumentsContract.isDocumentUri(appContext, uri) &&
            uri.authority == "com.android.externalstorage.documents"
        ) {
            val docId = DocumentsContract.getDocumentId(uri)
            val split = docId.split(":", limit = 2)
            if (split.size == 2 && split[0].equals("primary", ignoreCase = true)) {
                val candidate = File(Environment.getExternalStorageDirectory(), split[1])
                if (candidate.exists() && candidate.isFile && candidate.canRead()) {
                    return candidate.absolutePath
                }
            }
        }
        return null
    }

    private fun sanitiseModelFileName(rawName: String): String {
        val base = File(rawName).name
        val cleaned = base.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return if (cleaned.lowercase(Locale.ROOT).endsWith(".litertlm")) {
            cleaned
        } else {
            "$cleaned.litertlm"
        }
    }

    private fun postError(
        onError: (code: String, message: String) -> Unit,
        code: String,
        message: String,
    ) {
        mainHandler.post { onError(code, message) }
    }
}
