package com.jesusom.pulso.core

import android.content.Context
import com.jesusom.pulso.R
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

enum class Provider(val raw: String, val title: String) {
    CODEX("codex", "Codex"),
    COPILOT("copilot", "GitHub Copilot"),
    CLAUDE("claude", "Claude");

    companion object {
        fun from(raw: String?): Provider? = entries.firstOrNull { it.raw == raw }

        /**
         * Saved raw values in saved order; unknown or repeated values are dropped and providers
         * added later are appended in their canonical position.
         */
        fun ordered(raw: List<String>): List<Provider> {
            val result = raw.mapNotNull(::from).distinct()
            return result + entries.filter { it !in result }
        }
    }
}

enum class QuotaDisplay(val raw: String) {
    REMAINING("remaining"), USED("used");

    fun headline(c: Context) = c.getString(if (this == USED) R.string.s_usado else R.string.s_disponible)
    fun headlineNoun(c: Context) = c.getString(if (this == USED) R.string.s_usado_2 else R.string.s_disponible_2)
    fun complementNoun(c: Context) = c.getString(if (this == USED) R.string.s_disponible_2 else R.string.s_usado_2)

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw } ?: REMAINING
    }
}

data class UsageWindow(
    val id: String,
    /** Persisted provider titles stay in Spanish; display copy is resolved with [localizedTitle]. */
    val title: String,
    val used: Double,
    val limit: Double?,
    val resetsAt: Instant?,
    val remaining: Double? = null,
    val reportedRemainingPercent: Double? = null,
) {
    fun localizedTitle(c: Context): String = when (title) {
        "Sesión" -> c.getString(R.string.s_sesion)
        "Sesión · 5 h" -> c.getString(R.string.s_sesion_5_h)
        "Semana" -> c.getString(R.string.s_semana)
        "Semana · Opus" -> c.getString(R.string.s_semana_opus)
        "Semana · Sonnet" -> c.getString(R.string.s_semana_sonnet)
        "Mes" -> c.getString(R.string.s_mes)
        "Créditos del mes" -> c.getString(R.string.s_creditos_del_mes)
        "Créditos usados · cuenta" -> c.getString(R.string.s_creditos_usados_cuenta)
        "Premium · cuenta" -> c.getString(R.string.s_premium_cuenta)
        "Chat · cuenta" -> c.getString(R.string.s_chat_cuenta)
        "Mes · solicitudes premium" -> c.getString(R.string.s_mes_solicitudes_premium)
        "Mes · créditos IA" -> c.getString(R.string.s_mes_creditos_ia)
        else -> when {
            title.startsWith("Sesión · ") -> c.getString(R.string.s_sesion_2, title.removePrefix("Sesión · "))
            title.startsWith("Semana · ") -> c.getString(R.string.s_semana_2, title.removePrefix("Semana · "))
            else -> title
        }
    }

    val usedPercent: Double?
        get() {
            val limit = limit ?: return null
            if (!limit.isFinite() || limit <= 0 || !used.isFinite() || used < 0) return null
            return (used / limit * 100).coerceIn(0.0, 100.0)
        }

    /** Derived percentages stay complementary; independently reported balances take precedence. */
    val displayedUsedPercent: Int? get() = usedPercent?.let { Math.round(it).toInt() }

    private val validReportedRemaining: Double?
        get() = reportedRemainingPercent?.takeIf { it.isFinite() && it in 0.0..100.0 }

    val displayedRemainingPercent: Int?
        get() = validReportedRemaining?.let { Math.round(it).toInt() } ?: displayedUsedPercent?.let { 100 - it }

    val remainingPercent: Double?
        get() {
            validReportedRemaining?.let { return it }
            val limit = limit ?: return null
            if (!limit.isFinite() || limit <= 0 || !used.isFinite() || used < 0) return null
            return ((1 - used / limit) * 100).coerceIn(0.0, 100.0)
        }

    /** The headline figure and the complement shown beside it, so both readings stay visible. */
    fun displayedPercent(display: QuotaDisplay): Int? =
        if (display == QuotaDisplay.USED) displayedUsedPercent else displayedRemainingPercent

    fun complementPercent(display: QuotaDisplay): Int? =
        if (display == QuotaDisplay.USED) displayedRemainingPercent else displayedUsedPercent

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id); put("title", title); put("used", used)
        limit?.let { put("limit", it) }
        resetsAt?.let { put("resetsAt", it.epochSecond + it.nano / 1e9) }
        remaining?.let { put("remaining", it) }
        reportedRemainingPercent?.let { put("reportedRemainingPercent", it) }
    }

    companion object {
        fun fromJson(o: JSONObject) = UsageWindow(
            id = o.getString("id"), title = o.getString("title"), used = o.getDouble("used"),
            limit = o.optDoubleOrNull("limit"),
            resetsAt = o.optDoubleOrNull("resetsAt")?.let { Instant.ofEpochMilli((it * 1000).toLong()) },
            remaining = o.optDoubleOrNull("remaining"),
            reportedRemainingPercent = o.optDoubleOrNull("reportedRemainingPercent"),
        )
    }
}

internal fun JSONObject.optDoubleOrNull(name: String): Double? =
    if (has(name) && !isNull(name)) optDouble(name).takeIf { !it.isNaN() } else null

data class UsageSnapshot(
    val provider: Provider,
    val windows: List<UsageWindow>,
    val updatedAt: Instant,
    val source: String,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("provider", provider.raw)
        put("windows", JSONArray(windows.map { it.toJson() }))
        put("updatedAt", updatedAt.toEpochMilli() / 1000.0)
        put("source", source)
    }

    companion object {
        fun fromJson(o: JSONObject): UsageSnapshot? {
            val provider = Provider.from(o.optString("provider")) ?: return null
            val array = o.getJSONArray("windows")
            return UsageSnapshot(
                provider, (0 until array.length()).map { UsageWindow.fromJson(array.getJSONObject(it)) },
                Instant.ofEpochMilli((o.getDouble("updatedAt") * 1000).toLong()), o.optString("source"),
            )
        }
    }
}

/** Errors carry no text of their own: copy is resolved per language when displayed. */
interface LocalizedError {
    fun describe(c: Context): String
}

sealed class UsageError : Exception(), LocalizedError {
    object UnsupportedSchema : UsageError()
    object InvalidCredentials : UsageError()
    object InvalidAllowance : UsageError()
    object InvalidResponse : UsageError()
    object NoUsageData : UsageError()
    data class Http(val code: Int) : UsageError()

    override fun describe(c: Context): String = when (this) {
        UnsupportedSchema -> c.getString(R.string.s_el_proveedor_devolvio_datos_de_uso_no_compat)
        InvalidCredentials -> c.getString(R.string.s_introduce_un_usuario_y_un_token_validos)
        InvalidAllowance -> c.getString(R.string.s_el_limite_manual_debe_ser_un_numero_mayor_qu)
        NoUsageData -> c.getString(R.string.s_github_no_ha_devuelto_datos_de_consumo_para)
        InvalidResponse -> c.getString(R.string.s_no_se_pudo_verificar_la_respuesta_del_provee)
        is Http -> when (code) {
            401 -> c.getString(R.string.s_la_sesion_ha_caducado_o_el_token_no_es_valid)
            403 -> c.getString(R.string.s_acceso_denegado_comprueba_el_permiso_plan_de)
            404 -> c.getString(R.string.s_informe_no_disponible_comprueba_el_usuario_y)
            else -> c.getString(R.string.s_el_proveedor_no_pudo_completar_la_consulta_h, code)
        }
    }
}

fun Throwable.describe(c: Context): String = (this as? LocalizedError)?.describe(c) ?: (message ?: toString())

/** Stored diagnostics are also used for coordination; translate only when displaying them. */
fun localizedQuotaStatus(c: Context, status: String): String = when (status) {
    "En curso" -> c.getString(R.string.s_en_curso)
    "Actualizado" -> c.getString(R.string.s_actualizado)
    "Tiempo de ejecución agotado" -> c.getString(R.string.s_tiempo_de_ejecucion_agotado)
    "Sin proveedores conectados" -> c.getString(R.string.s_sin_proveedores_conectados)
    else -> status
}

/** Seconds since the epoch as JSON, shared with the parsers. */
internal fun epochToInstant(seconds: Double): Instant = Instant.ofEpochMilli((seconds * 1000).toLong())
