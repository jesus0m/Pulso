package com.jesusom.pulso.core

import org.json.JSONArray
import org.json.JSONObject

/** Mirrors Swift's strict Codable decoding: a value of the wrong type is a schema failure. */
internal class SchemaException : Exception()

internal fun parseObject(data: ByteArray): JSONObject =
    try { JSONObject(String(data, Charsets.UTF_8)) } catch (e: Exception) { throw SchemaException() }

/** Present non-null value, or null when the key is absent or JSON null. */
private fun JSONObject.raw(name: String): Any? = if (!has(name) || isNull(name)) null else get(name)

internal fun JSONObject.strictDouble(name: String): Double? = when (val v = raw(name)) {
    null -> null
    is Number -> v.toDouble()
    else -> throw SchemaException()
}

internal fun JSONObject.requiredDouble(name: String): Double = strictDouble(name) ?: throw SchemaException()

internal fun JSONObject.requiredInt(name: String): Int {
    val v = requiredDouble(name)
    if (v != Math.floor(v) || v > Int.MAX_VALUE || v < Int.MIN_VALUE) throw SchemaException()
    return v.toInt()
}

internal fun JSONObject.strictBoolean(name: String): Boolean? = when (val v = raw(name)) {
    null -> null
    is Boolean -> v
    else -> throw SchemaException()
}

internal fun JSONObject.strictString(name: String): String? = when (val v = raw(name)) {
    null -> null
    is String -> v
    else -> throw SchemaException()
}

internal fun JSONObject.requiredString(name: String): String = strictString(name) ?: throw SchemaException()

internal fun JSONObject.strictObject(name: String): JSONObject? = when (val v = raw(name)) {
    null -> null
    is JSONObject -> v
    else -> throw SchemaException()
}

internal fun JSONObject.requiredArray(name: String): JSONArray = when (val v = raw(name)) {
    is JSONArray -> v
    else -> throw SchemaException()
}

internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map {
    get(it) as? JSONObject ?: throw SchemaException()
}
