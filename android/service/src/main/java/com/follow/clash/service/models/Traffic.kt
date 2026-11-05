package com.follow.clash.service.models

import com.follow.clash.common.GlobalState
import com.follow.clash.core.Core
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName

private val gson = Gson()

data class Traffic(
    val up: Long,
    val down: Long,
)

private val Long.formatBytes: String
    get() {
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var value = toDouble()
        var unit = 0
        while (value >= 1024 && unit < units.lastIndex) {
            value /= 1024
            unit++
        }
        return if (unit == 0) {
            "${value.toLong()}${units[unit]}"
        } else {
            "%.1f${units[unit]}".format(value)
        }
    }

val Traffic.speedText: String
    get() = "${up.formatBytes}/s↑  ${down.formatBytes}/s↓"

data class TrafficStats(
    val up: Long,
    val down: Long,
    @SerializedName("total-up") val totalUp: Long,
    @SerializedName("total-down") val totalDown: Long,
)

fun TrafficStats.speedText(): String = "${up.formatBytes}/s↑  ${down.formatBytes}/s↓"

fun Core.getSpeedTrafficText(onlyStatisticsProxy: Boolean): String {
    return runCatching {
        gson.fromJson(getTrafficStats(onlyStatisticsProxy), TrafficStats::class.java).speedText()
    }.onFailure { error ->
        GlobalState.log("Unable to read traffic: $error")
    }.getOrDefault("")
}
