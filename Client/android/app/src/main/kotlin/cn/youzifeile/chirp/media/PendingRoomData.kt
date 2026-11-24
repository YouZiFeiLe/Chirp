package cn.youzifeile.chirp.media

/** A peer can receive its new lease first. Retain only ciphertext for a locally staged slot. */
internal class PendingRoomData(private val leased: (Int) -> Long?, private val staged: (Int) -> Long?) {
    private class Packet(val index: Int, val epoch: Long, val deliver: (Long) -> Unit)
    private val waiting = ArrayDeque<Packet>()

    @Synchronized fun receive(index: Int, wireBytes: Int, deliver: (Long) -> Unit) {
        if (wireBytes !in 1..65535) return
        val candidate = staged(index)
        val epoch = leased(index)
        drain()
        if (epoch != null) {
            deliver(epoch)
            return
        }
        // At most 32 LiveKit data packets (under 2 MiB) per room during a cutover.
        if (candidate != null && waiting.size < 32) waiting.addLast(Packet(index, candidate, deliver))
    }

    // Serialize delivery with new arrivals so a newer sequence cannot overtake a queued message.
    @Synchronized fun drain() {
        val packets = waiting.iterator()
        while (packets.hasNext()) {
            val packet = packets.next()
            val candidate = staged(packet.index)
            if (leased(packet.index) == packet.epoch) {
                packets.remove()
                packet.deliver(packet.epoch)
            } else if (candidate != packet.epoch) {
                packets.remove()
            }
        }
    }

    @Synchronized fun clear() = waiting.clear()
}
