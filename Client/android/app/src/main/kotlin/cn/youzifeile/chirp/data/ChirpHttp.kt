package cn.youzifeile.chirp.data

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.JsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionPool
import okhttp3.Dispatcher
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.HttpUrl
import okio.BufferedSink

internal data class ChirpEvent(val name: String, val data: String)

internal class ChirpHttp(builder: OkHttpClient.Builder = OkHttpClient.Builder(), private val log: ClientLog? = ClientLog.current) {
    private val disabledMembers = MutableSharedFlow<String>(extraBufferCapacity = 16, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    suspend fun awaitDisabled(credential: String) {
        disabledMembers.first { it == credential }
    }

    val client = builder
        .dispatcher(Dispatcher().apply { maxRequestsPerHost = 16 })
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .connectTimeout(7, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    // The registration tab can outlive a pooled connection. Allow OkHttp to reconnect for reads.
    private val getClient = client.newBuilder().retryOnConnectionFailure(true).build()

    suspend fun json(
        request: Request,
        expected: Set<Int> = setOf(200),
        limit: Long = 65_536,
        timeout: Long = 10_000,
        operation: LogEvent = LogEvent.request,
    ): Pair<Int, JsonObject> = execute(operation, request, timeout) { response ->
        response.requireStatus(expected)
        val bytes = response.body.boundedBytes(limit)
        val obj = if (bytes.isEmpty() && response.code == 204) JsonObject(emptyMap()) else parseObject(bytes)
        response.code to obj
    }

    suspend fun binary(request: Request, limit: Long, timeout: Long = 10_000, contentType: String? = null,
        operation: LogEvent = LogEvent.request): ByteArray =
        execute(operation, request, timeout) { response ->
            response.requireStatus(setOf(200))
            if (contentType != null) verify(response.body.contentType()?.let { "${it.type}/${it.subtype}" } == contentType, "INVALID_RESPONSE")
            response.body.boundedBytes(limit)
        }

    fun events(request: Request, operation: LogEvent): Flow<ChirpEvent> = callbackFlow {
        val span = log?.begin(operation)
        val call = client.newCall(request)
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                span?.finish(if (call.isCanceled()) kotlinx.coroutines.CancellationException() else e)
                close(e)
            }

            override fun onResponse(call: Call, response: Response) {
                try {
                    span?.httpStatus = response.code
                    response.use {
                        it.requireStatus(setOf(200))
                        verify(it.body.contentType()?.let { type ->
                            type.type == "text" && type.subtype == "event-stream"
                        } == true)
                        val source = it.body.source()
                        var event = "message"
                        var data: String? = null
                        while (!call.isCanceled()) {
                            val line = source.readUtf8LineStrict(65_536)
                            when {
                                line.isEmpty() -> {
                                    val payload = data
                                    if (payload != null && trySend(ChirpEvent(event, payload)).isFailure) {
                                        throw IOException("Event consumer fell behind")
                                    }
                                    event = "message"
                                    data = null
                                }
                                line.startsWith("event:") -> event = line.substring(6).trim()
                                line.startsWith("data:") -> {
                                    val value = line.substring(5).removePrefix(" ")
                                    data = data?.let { prior -> "$prior\n$value" } ?: value
                                    verify(data.length <= 65_536)
                                }
                            }
                        }
                    }
                    span?.finish(if (call.isCanceled()) kotlinx.coroutines.CancellationException() else null)
                    close()
                } catch (e: Exception) {
                    span?.finish(if (call.isCanceled()) kotlinx.coroutines.CancellationException() else e)
                    close(e)
                }
            }
        })
        awaitClose { call.cancel() }
    }

    private suspend fun <T> execute(operation: LogEvent, request: Request, timeout: Long, parse: (Response) -> T): T {
        val span = log?.begin(operation)
        try {
            val result = suspendCancellableCoroutine<T> { continuation ->
                val requestClient = when {
                    // A browser round trip can leave a stale socket. Give just this exchange its own pool.
                    request.body is LoginCodeBody -> client.newBuilder()
                        .connectionPool(ConnectionPool(0, 1, TimeUnit.SECONDS))
                        .build()
                    request.method == "GET" -> getClient
                    else -> client
                }
                val call = requestClient.newCall(request)
                call.timeout().timeout(timeout, TimeUnit.MILLISECONDS)
                continuation.invokeOnCancellation { call.cancel() }
                call.enqueue(object : Callback {
                    override fun onFailure(call: Call, e: IOException) {
                        continuation.resumeWithException(e)
                    }

                    override fun onResponse(call: Call, response: Response) {
                        span?.httpStatus = response.code
                        val result = runCatching { response.use(parse) }
                        continuation.resumeWith(result)
                    }
                })
            }
            span?.finish()
            return result
        } catch (e: Exception) {
            span?.finish(e)
            throw e
        }
    }

    private fun Response.requireStatus(expected: Set<Int>) {
        if (code in expected) return
        val envelope = runCatching { parseObject(body.boundedBytes(16_384)) }.getOrNull()
        val rawCode = runCatching { envelope?.obj("error")?.text("code") }.getOrNull()
        val error = rawCode?.takeIf(clientErrorCode::matches) ?: if (code == 401) "SESSION_EXPIRED" else "CLIENT_HTTP_FAILURE"
        val policy = (envelope?.get("client_policy") as? JsonObject)?.let { runCatching { VersionPolicy.parse(it) }.getOrNull() }
        if (code == 403 && error == "MEMBER_DISABLED") {
            request.header("Authorization")?.takeIf { it.startsWith("Bearer ") }?.let {
                disabledMembers.tryEmit(it.removePrefix("Bearer "))
            }
        }
        throw ChirpException(error, code, retryDelay(code, header("Retry-After")), policy,
            if (rawCode != null && !clientErrorCode.matches(rawCode)) "CLIENT_UNKNOWN_SERVER_ERROR" else error)
    }
}

internal fun retryDelay(status: Int, header: String?, now: java.time.Instant = java.time.Instant.now()): Long? {
    if (status != 429 && status !in 500..599) return null
    val value = header?.trim() ?: return null
    value.toLongOrNull()?.let { return it.takeIf { seconds -> seconds > 0 } }
    val deadline = runCatching {
        java.time.ZonedDateTime.parse(value, java.time.format.DateTimeFormatter.RFC_1123_DATE_TIME).toInstant()
    }.getOrNull() ?: return null
    return (deadline.epochSecond - now.epochSecond).takeIf { it > 0 }
}

internal fun parseObject(bytes: ByteArray): JsonObject = try {
    wireJson.parseToJsonElement(bytes.decodeToString(throwOnInvalidSequence = true)) as JsonObject
} catch (_: Exception) {
    throw ChirpException("INVALID_RESPONSE")
}

private fun ResponseBody.boundedBytes(limit: Long): ByteArray {
    verify(contentLength() <= limit)
    val source = source()
    verify(!source.request(limit + 1))
    return source.readByteArray()
}

internal fun Request.Builder.jsonPost(value: JsonObject): Request.Builder = post(value.jsonBody())
internal fun JsonObject.jsonBody(): RequestBody = toString().toRequestBody("application/json".toMediaType())

internal class LoginCodeBody(payload: JsonObject) : RequestBody() {
    private val json = payload.jsonBody()
    override fun contentType() = json.contentType()
    override fun contentLength() = json.contentLength()
    override fun writeTo(sink: BufferedSink) = json.writeTo(sink)
    override fun isOneShot() = true
}

internal fun HttpUrl.request(credential: String? = null): Request.Builder =
    Request.Builder().url(this).header("Accept", "application/json").apply {
        credential?.let { header("Authorization", "Bearer $it") }
    }
