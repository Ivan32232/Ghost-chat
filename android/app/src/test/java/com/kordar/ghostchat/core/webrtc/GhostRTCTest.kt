package com.kordar.ghostchat.core.webrtc

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class GhostRTCTest {

    @Test
    fun `host candidate is rejected`() {
        assertThat(GhostRTC.shouldAcceptCandidate(
            "candidate:1 1 UDP 2122260223 192.168.1.2 54400 typ host generation 0"
        )).isFalse()
    }

    @Test
    fun `ipv6 link local is rejected`() {
        assertThat(GhostRTC.shouldAcceptCandidate(
            "candidate:2 1 UDP 2122194687 fe80::1234:5678:abcd:ef12 54401 typ srflx generation 0"
        )).isFalse()
    }

    @Test
    fun `srflx public candidate is accepted`() {
        assertThat(GhostRTC.shouldAcceptCandidate(
            "candidate:3 1 UDP 1686052607 203.0.113.7 54402 typ srflx raddr 192.168.1.2 rport 54400 generation 0"
        )).isTrue()
    }

    @Test
    fun `relay candidate is accepted`() {
        assertThat(GhostRTC.shouldAcceptCandidate(
            "candidate:4 1 UDP 41887999 139.59.58.151 5349 typ relay raddr 0.0.0.0 rport 0 generation 0"
        )).isTrue()
    }

    @Test
    fun `data channel label constant is ghost-chat`() {
        assertThat(GhostRTC.DATA_CHANNEL_LABEL).isEqualTo("ghost-chat")
    }
}
