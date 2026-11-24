package cn.youzifeile.chirp.media

import cn.youzifeile.chirp.data.*
import kotlinx.serialization.json.*

internal data class RoomPublicInformation(val serverTime: Long, val interval: Long, val epoch: ULong,
    val members: Int, val reason: String, val established: Long?, val last: Long?, val next: Long?,
    val phase: String?, val confirmed: Int, val activated: Int, val started: Long) {
    fun fresh(now: Long) = now - started in 0 until 6000
    fun countdown(now: Long): Long? = next?.takeIf { fresh(now) }
        ?.let { ((it - serverTime - (now - started)).coerceAtLeast(0) + 999) / 1000 }
    companion object {
        fun read(response: JsonObject, group: GroupSnapshot, started: Long): RoomPublicInformation? = runCatching {
            if (group.status.suspended) return null
            val i = response.obj("room_information")
            fun time(k: String) = if (k in i) i.long(k) else null
            val value = RoomPublicInformation(i.long("server_time_ms"),i.long("rotation_interval_ms"),i.unsigned("key_epoch"),
                i.int("member_count"),i.text("update_reason"), time("established_at_ms"),time("last_rotation_at_ms"),
                time("next_rotation_at_ms"),i["rotation_phase"]?.jsonPrimitive?.content,
                if ("confirmed_members" in i) i.int("confirmed_members") else 0,
                if ("activated_members" in i) i.int("activated_members") else 0,started)
            with(value) {
                verify(serverTime in 1 until 253402300799000 && interval in 1..86_400_000 && members == group.members.size &&
                    members > 0 && epoch == group.status.keyEpoch && epoch < ULong.MAX_VALUE && reason in setOf("initial_connection","members_changed","scheduled_rotation","connection_recovery") &&
                    confirmed in 0..members && activated in 0..confirmed && phase == group.rotation?.phase &&
                    (if ("rotation_epoch" in i) i.unsigned("rotation_epoch") else null) == group.rotation?.epoch &&
                    (phase != null || confirmed == 0 && activated == 0) && listOfNotNull(last,established).all { it in 1..serverTime } &&
                    (last == null || epoch > 0UL && established != null && last >= established) &&
                    (next == null || established != null && next in 1..serverTime+interval))
            }
            value
        }.getOrNull()
    }
}
