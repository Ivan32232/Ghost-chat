package com.kordar.ghostchat

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.fragment.app.FragmentActivity
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.kordar.ghostchat.core.managers.CallManager
import com.kordar.ghostchat.core.managers.ConnectionManager
import com.kordar.ghostchat.features.call.CallScreen
import com.kordar.ghostchat.features.chat.ChatScreen
import com.kordar.ghostchat.features.contacts.ContactDetailScreen
import com.kordar.ghostchat.features.contacts.ContactsScreen
import com.kordar.ghostchat.features.nav.Destinations
import com.kordar.ghostchat.features.settings.LockScreen
import com.kordar.ghostchat.features.settings.SecurityDashboardScreen
import com.kordar.ghostchat.features.settings.SettingsScreen
import com.kordar.ghostchat.features.settings.SettingsViewModel
import com.kordar.ghostchat.features.welcome.WelcomeScreen
import com.kordar.ghostchat.models.Room
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Root Activity. FragmentActivity subclass so BiometricPrompt can host its fragment.
 * FLAG_SECURE set as early as possible so the window is excluded from recent-apps
 * preview, screenshots, and screen-recording APIs.
 */
@AndroidEntryPoint
class MainActivity : FragmentActivity() {

    @Inject lateinit var callManager: CallManager
    @Inject lateinit var connection: ConnectionManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
        setContent {
            GhostChatTheme { RootNavHost(intent = intent, handleDeepLink = ::handleDeepLink) }
        }
    }

    override fun onNewIntent(newIntent: Intent) {
        super.onNewIntent(newIntent)
        setIntent(newIntent)
        handleDeepLink(newIntent.data)
    }

    private fun handleDeepLink(uri: Uri?) {
        val candidate = extractRoomId(uri) ?: return
        if (!Room.isValidId(candidate)) return
        lifecycleScope.launch { connection.joinRoom(candidate) }
    }

    private fun extractRoomId(uri: Uri?): String? {
        uri ?: return null
        if (uri.scheme == "ghostchat") return uri.pathSegments.lastOrNull() ?: uri.host
        if (uri.scheme?.startsWith("http") == true) return uri.getQueryParameter("room")
        return null
    }
}

@Composable
fun GhostChatTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(),
        typography = com.kordar.ghostchat.ui.theme.GhostTypography
    ) { content() }
}

@Composable
private fun RootNavHost(
    intent: Intent?,
    handleDeepLink: (Uri?) -> Unit
) {
    val nav = rememberNavController()
    val settingsVm: SettingsViewModel = hiltViewModel()
    var locked by remember {
        mutableStateOf(settingsVm.auth.biometricEnabled && settingsVm.auth.hasMainPIN())
    }
    val lifecycleOwner = LocalLifecycleOwner.current

    LaunchedEffect(lifecycleOwner) {
        val observer = object : DefaultLifecycleObserver {
            override fun onStop(owner: LifecycleOwner) {
                if (settingsVm.auth.biometricEnabled && settingsVm.auth.hasMainPIN()) {
                    locked = true
                }
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
    }

    LaunchedEffect(intent) { handleDeepLink(intent?.data) }

    if (locked) {
        androidx.compose.foundation.layout.Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black)
        ) {
            LockScreen(onUnlocked = { locked = false }, onDecoy = { locked = false })
        }
        return
    }

    NavHost(navController = nav, startDestination = Destinations.WELCOME) {
        composable(Destinations.WELCOME) {
            WelcomeScreen(
                onOpenChat     = { nav.navigate(Destinations.CHAT) },
                onOpenSettings = { nav.navigate(Destinations.SETTINGS) },
                onOpenContacts = { nav.navigate(Destinations.CONTACTS) }
            )
        }
        composable(Destinations.CHAT) {
            ChatScreen(
                onLeave    = { nav.popBackStack(Destinations.WELCOME, inclusive = false) },
                onStartCall = { nav.navigate(Destinations.CALL) }
            )
        }
        composable(Destinations.CALL) {
            CallScreen(onDismiss = { nav.popBackStack() })
        }
        composable(Destinations.CONTACTS) {
            ContactsScreen(
                onOpenContact = { id -> nav.navigate(Destinations.contactDetail(id)) }
            )
        }
        composable(
            route = Destinations.CONTACT_DETAIL,
            arguments = listOf(navArgument("contactId") { type = NavType.StringType })
        ) { entry ->
            val id = entry.arguments?.getString("contactId").orEmpty()
            ContactDetailScreen(contactId = id, onBack = { nav.popBackStack() })
        }
        composable(Destinations.SETTINGS) {
            SettingsScreen(
                onOpenDashboard = { nav.navigate(Destinations.SECURITY_DASHBOARD) },
                onOpenAbout     = { nav.navigate(Destinations.ABOUT) }
            )
        }
        composable(Destinations.SECURITY_DASHBOARD) {
            val owner = androidx.compose.ui.platform.LocalContext.current as? MainActivity
            owner?.let { SecurityDashboardScreen(connection = it.connection) }
        }
        composable(Destinations.ABOUT) {
            com.kordar.ghostchat.features.settings.AboutScreen()
        }
    }
}
