package com.kordar.ghostchat.core.crypto

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Binary serialization of [DoubleRatchet] internal state. Format is internal-only (not shared
 * cross-platform) and deliberately compact.
 *
 * Layout (big-endian, fixed-width where possible):
 *   magic(4): 'G','D','R','1'
 *   version(1): 0x01
 *   dhs_private(32): scalar bytes
 *   has_dhr(1) + dhr_raw(64, optional)
 *   rk(32)
 *   has_cks(1) + cks(32, optional)
 *   has_ckr(1) + ckr(32, optional)
 *   ns(4) nr(4) pn(4)
 *   has_lastDHr(1) + lastDHr(64, optional)
 *   mkSkipped_count(4) + N × (keyStr: utf8 len(2) + bytes) + (messageKey: 32)
 */
internal object DoubleRatchetState {

    private val MAGIC = byteArrayOf('G'.code.toByte(), 'D'.code.toByte(), 'R'.code.toByte(), '1'.code.toByte())
    private const val VERSION: Byte = 0x01

    internal data class Snapshot(
        val dhsPrivateBytes: ByteArray,
        val dhrRaw: ByteArray?,
        val rk: ByteArray,
        val cks: ByteArray?,
        val ckr: ByteArray?,
        val ns: Int,
        val nr: Int,
        val pn: Int,
        val lastDHr: ByteArray?,
        val mkSkipped: Map<String, ByteArray>
    )

    internal fun serialize(snap: Snapshot): ByteArray {
        val entries = snap.mkSkipped.entries.toList()
        val capacity = MAGIC.size + 1 +
            32 +
            1 + (if (snap.dhrRaw != null) 64 else 0) +
            32 +
            1 + (if (snap.cks != null) 32 else 0) +
            1 + (if (snap.ckr != null) 32 else 0) +
            4 + 4 + 4 +
            1 + (if (snap.lastDHr != null) 64 else 0) +
            4 + entries.sumOf { 2 + it.key.toByteArray(Charsets.UTF_8).size + 32 }
        val buf = ByteBuffer.allocate(capacity).order(ByteOrder.BIG_ENDIAN)
        buf.put(MAGIC)
        buf.put(VERSION)
        require(snap.dhsPrivateBytes.size == 32) { "dhs_private must be 32 bytes" }
        buf.put(snap.dhsPrivateBytes)
        if (snap.dhrRaw != null) {
            require(snap.dhrRaw.size == 64) { "dhr_raw must be 64 bytes" }
            buf.put(1.toByte()); buf.put(snap.dhrRaw)
        } else buf.put(0.toByte())
        require(snap.rk.size == 32) { "rk must be 32 bytes" }
        buf.put(snap.rk)
        putOptional(buf, snap.cks, 32)
        putOptional(buf, snap.ckr, 32)
        buf.putInt(snap.ns); buf.putInt(snap.nr); buf.putInt(snap.pn)
        if (snap.lastDHr != null) {
            require(snap.lastDHr.size == 64) { "lastDHr must be 64 bytes" }
            buf.put(1.toByte()); buf.put(snap.lastDHr)
        } else buf.put(0.toByte())
        buf.putInt(entries.size)
        for ((k, v) in entries) {
            val keyBytes = k.toByteArray(Charsets.UTF_8)
            require(keyBytes.size <= 0xFFFF) { "mkSkipped key too long" }
            buf.putShort(keyBytes.size.toShort())
            buf.put(keyBytes)
            require(v.size == 32) { "messageKey must be 32 bytes" }
            buf.put(v)
        }
        return buf.array()
    }

    internal fun deserialize(data: ByteArray): Snapshot {
        val buf = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
        val magic = ByteArray(4).also { buf.get(it) }
        require(magic.contentEquals(MAGIC)) { "bad magic" }
        val version = buf.get()
        require(version == VERSION) { "unsupported state version: $version" }
        val dhsPriv = ByteArray(32).also { buf.get(it) }
        val hasDhr = buf.get().toInt() != 0
        val dhrRaw = if (hasDhr) ByteArray(64).also { buf.get(it) } else null
        val rk = ByteArray(32).also { buf.get(it) }
        val cks = if (buf.get().toInt() != 0) ByteArray(32).also { buf.get(it) } else null
        val ckr = if (buf.get().toInt() != 0) ByteArray(32).also { buf.get(it) } else null
        val ns = buf.int
        val nr = buf.int
        val pn = buf.int
        val lastDHr = if (buf.get().toInt() != 0) ByteArray(64).also { buf.get(it) } else null
        val skipCount = buf.int
        val mkSkipped = mutableMapOf<String, ByteArray>()
        repeat(skipCount) {
            val keyLen = buf.short.toInt() and 0xFFFF
            val keyBytes = ByteArray(keyLen).also { buf.get(it) }
            val value = ByteArray(32).also { buf.get(it) }
            mkSkipped[String(keyBytes, Charsets.UTF_8)] = value
        }
        return Snapshot(dhsPriv, dhrRaw, rk, cks, ckr, ns, nr, pn, lastDHr, mkSkipped)
    }

    private fun putOptional(buf: ByteBuffer, value: ByteArray?, expected: Int) {
        if (value != null) {
            require(value.size == expected)
            buf.put(1.toByte()); buf.put(value)
        } else {
            buf.put(0.toByte())
        }
    }
}
