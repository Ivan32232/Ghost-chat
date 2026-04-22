package com.kordar.ghostchat.features.nav

/**
 * Navigation graph routes. Keep the identifiers short — they get used as query
 * arguments to `NavController.navigate`.
 */
object Destinations {
    const val WELCOME   = "welcome"
    const val WAITING   = "waiting/{roomId}"
    const val CONNECTING = "connecting"
    const val CHAT      = "chat"
    const val CALL      = "call"
    const val CONTACTS  = "contacts"
    const val CONTACT_DETAIL = "contact_detail/{contactId}"
    const val SETTINGS  = "settings"
    const val LOCK      = "lock"
    const val SECURITY_DASHBOARD = "security_dashboard"
    const val ABOUT     = "about"

    fun contactDetail(contactId: String) = "contact_detail/$contactId"
    fun waiting(roomId: String) = "waiting/$roomId"
}
