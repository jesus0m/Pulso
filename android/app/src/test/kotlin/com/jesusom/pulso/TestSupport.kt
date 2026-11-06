package com.jesusom.pulso

import android.content.SharedPreferences
import com.jesusom.pulso.core.HttpRequest
import com.jesusom.pulso.core.HttpResponse
import com.jesusom.pulso.core.HttpTransport
import com.jesusom.pulso.core.PulsoPrefs
import java.time.Instant

val NOW: Instant = Instant.ofEpochSecond(1_793_750_400)

fun bytes(text: String) = text.toByteArray()

/** In-memory SharedPreferences so storage logic runs on the JVM. */
class FakeSharedPreferences : SharedPreferences {
    private val values = HashMap<String, Any?>()

    override fun getAll(): MutableMap<String, *> = HashMap(values)
    override fun getString(key: String, defValue: String?) = values[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String, defValues: MutableSet<String>?) = values[key] as? MutableSet<String> ?: defValues
    override fun getInt(key: String, defValue: Int) = values[key] as? Int ?: defValue
    override fun getLong(key: String, defValue: Long) = values[key] as? Long ?: defValue
    override fun getFloat(key: String, defValue: Float) = values[key] as? Float ?: defValue
    override fun getBoolean(key: String, defValue: Boolean) = values[key] as? Boolean ?: defValue
    override fun contains(key: String) = values.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
    override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val pending = HashMap<String, Any?>()
        private val removals = HashSet<String>()
        private var clear = false
        override fun putString(key: String, value: String?) = apply { pending[key] = value }
        override fun putStringSet(key: String, values: MutableSet<String>?) = apply { pending[key] = values }
        override fun putInt(key: String, value: Int) = apply { pending[key] = value }
        override fun putLong(key: String, value: Long) = apply { pending[key] = value }
        override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
        override fun remove(key: String) = apply { removals += key }
        override fun clear() = apply { clear = true }
        override fun commit(): Boolean { apply(); return true }
        override fun apply() {
            if (clear) values.clear()
            removals.forEach { values.remove(it) }
            values.putAll(pending)
        }
    }
}

fun fakePrefs() = PulsoPrefs(FakeSharedPreferences())

/** Scripted transport: records requests and answers with a canned response. */
class FakeTransport(private val handler: (HttpRequest) -> HttpResponse) : HttpTransport {
    val requests = mutableListOf<HttpRequest>()
    override suspend fun execute(request: HttpRequest): HttpResponse {
        requests += request
        return handler(request)
    }
}

fun response(
    status: Int, body: String = "", headers: Map<String, String> = emptyMap(), url: String = "",
    multi: Map<String, List<String>> = emptyMap(),
) = HttpResponse(
    status, headers.mapKeys { it.key.lowercase() }.mapValues { listOf(it.value) } + multi.mapKeys { it.key.lowercase() },
    body.toByteArray(), url,
)
