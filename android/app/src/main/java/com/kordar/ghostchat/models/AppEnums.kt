package com.kordar.ghostchat.models

/**
 * Mirror of iOS `Models/AppEnums.swift`. Keep cases byte-for-byte identical to
 * iOS so the two platforms can share any persisted/transport payloads.
 */

enum class ConnectionState(val wire: String) {
    DISCONNECTED("disconnected"),
    CONNECTING("connecting"),
    SIGNALING("signaling"),
    WEB_RTC("webRTC"),
    CONNECTED("connected"),
    ENCRYPTED("encrypted");

    companion object {
        fun fromWire(value: String): ConnectionState =
            values().firstOrNull { it.wire == value } ?: DISCONNECTED
    }
}

enum class CallState(val wire: String) {
    IDLE("idle"),
    OUTGOING_PENDING("outgoingPending"),
    OUTGOING_RINGING("outgoingRinging"),
    INCOMING("incoming"),
    ACTIVE("active"),
    ENDED("ended");

    companion object {
        fun fromWire(value: String): CallState =
            values().firstOrNull { it.wire == value } ?: IDLE
    }
}

enum class Role(val wire: String) {
    HOST("host"),
    GUEST("guest");

    companion object {
        fun fromWire(value: String): Role =
            values().firstOrNull { it.wire == value } ?: HOST
    }
}

enum class Sender(val raw: Int) {
    ME(0),
    PEER(1),
    SYSTEM(2);

    companion object {
        fun fromRaw(raw: Int): Sender = values().firstOrNull { it.raw == raw } ?: ME
    }
}

enum class MessageType(val raw: Int) {
    TEXT(0),
    FILE(1),
    VOICE(2),
    SYSTEM(3);

    companion object {
        fun fromRaw(raw: Int): MessageType = values().firstOrNull { it.raw == raw } ?: TEXT
    }
}

enum class MessageTTL(val seconds: Int, val localizedKey: String) {
    THIRTY_SECONDS(30, "ttl.thirty_seconds"),
    ONE_MINUTE(60, "ttl.one_minute"),
    FIVE_MINUTES(300, "ttl.five_minutes"),
    FIFTEEN_MINUTES(900, "ttl.fifteen_minutes"),
    ONE_HOUR(3600, "ttl.one_hour");

    companion object {
        fun fromSeconds(seconds: Int): MessageTTL =
            values().firstOrNull { it.seconds == seconds } ?: FIVE_MINUTES
    }
}

enum class AutoLockTimeout(val seconds: Int) {
    IMMEDIATE(0),
    THIRTY_SECONDS(30),
    ONE_MINUTE(60),
    FIVE_MINUTES(300),
    THIRTY_MINUTES(1800);

    companion object {
        fun fromSeconds(seconds: Int): AutoLockTimeout =
            values().firstOrNull { it.seconds == seconds } ?: ONE_MINUTE
    }
}
