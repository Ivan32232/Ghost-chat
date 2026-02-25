package com.ghost.chat

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghost.chat.core.audio.SoundLibrary
import com.ghost.chat.core.localization.LocalizationManager
import com.ghost.chat.core.security.BiometricAuthService
import com.ghost.chat.core.security.SecurityMonitor
import com.ghost.chat.features.chat.ChatScreen
import com.ghost.chat.features.chat.ChatViewModel
import com.ghost.chat.features.contacts.ContactsScreen
import com.ghost.chat.features.contacts.ContactsViewModel
import com.ghost.chat.features.settings.LanguagePickerScreen
import com.ghost.chat.features.settings.SettingsScreen
import com.ghost.chat.features.settings.SoundPickerScreen
import com.ghost.chat.features.welcome.WelcomeScreen
import com.ghost.chat.ui.theme.*

class MainActivity : ComponentActivity() {

    private lateinit var chatViewModel: ChatViewModel
    private lateinit var contactsViewModel: ContactsViewModel

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(LocalizationManager.applyLocale(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Apply FLAG_SECURE (prevent screenshots/recording)
        SecurityMonitor.applyFlagSecure(this)

        chatViewModel = ChatViewModel(applicationContext)
        contactsViewModel = ContactsViewModel(applicationContext)

        // Handle deep link
        handleIntent(intent)

        setContent {
            GhostChatTheme {
                GhostChatApp(
                    chatViewModel = chatViewModel,
                    contactsViewModel = contactsViewModel,
                    onLanguageChanged = {
                        // Recreate activity to apply new locale
                        recreate()
                    }
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        intent ?: return
        val data = intent.data ?: return

        // Handle: https://gbskgs.xyz/?room=ROOM_ID
        val roomId = data.getQueryParameter("room")
        if (roomId != null) {
            chatViewModel.handleDeepLink(roomId)
            return
        }

        // Handle: ghostchat://room/ROOM_ID
        if (data.scheme == "ghostchat") {
            val pathRoom = data.pathSegments.firstOrNull()
            if (pathRoom != null) {
                chatViewModel.handleDeepLink(pathRoom)
            }
        }
    }

    override fun onPause() {
        super.onPause()
        BiometricAuthService.lock()
    }

    override fun onDestroy() {
        super.onDestroy()
        SoundLibrary.stopPreview()
    }
}

// MARK: - App Navigation

enum class AppScreen {
    MAIN, SETTINGS, CONTACTS, LANGUAGE_PICKER, SOUND_PICKER, RINGTONE_PICKER
}

@Composable
fun GhostChatApp(
    chatViewModel: ChatViewModel,
    contactsViewModel: ContactsViewModel,
    onLanguageChanged: () -> Unit
) {
    var currentScreen by remember { mutableStateOf(AppScreen.MAIN) }

    when (currentScreen) {
        AppScreen.MAIN -> MainScreen(
            chatViewModel = chatViewModel,
            onOpenSettings = { currentScreen = AppScreen.SETTINGS },
            onOpenContacts = { currentScreen = AppScreen.CONTACTS }
        )

        AppScreen.SETTINGS -> SettingsScreen(
            viewModel = chatViewModel,
            onBack = { currentScreen = AppScreen.MAIN },
            onLanguagePicker = { currentScreen = AppScreen.LANGUAGE_PICKER },
            onSoundPicker = { currentScreen = AppScreen.SOUND_PICKER },
            onRingtonePicker = { currentScreen = AppScreen.RINGTONE_PICKER }
        )

        AppScreen.CONTACTS -> ContactsScreen(
            viewModel = contactsViewModel,
            onBack = { currentScreen = AppScreen.MAIN },
            onStartChat = { contact ->
                chatViewModel.startChatWithContact(contact)
                currentScreen = AppScreen.MAIN
            }
        )

        AppScreen.LANGUAGE_PICKER -> LanguagePickerScreen(
            onBack = { currentScreen = AppScreen.SETTINGS },
            onLanguageSelected = { lang ->
                LocalizationManager.setLanguage(
                    lang,
                    chatViewModel.let { it::class.java.getDeclaredField("appContext").apply { isAccessible = true }.get(it) as android.content.Context }
                )
                onLanguageChanged()
            }
        )

        AppScreen.SOUND_PICKER -> SoundPickerScreen(
            title = stringResource(R.string.settings_msg_sound),
            sounds = SoundLibrary.messageSounds,
            currentId = chatViewModel.messageSoundId,
            onBack = { currentScreen = AppScreen.SETTINGS },
            onSelect = { id ->
                chatViewModel.messageSoundId = id
                chatViewModel.saveSettings()
                currentScreen = AppScreen.SETTINGS
            }
        )

        AppScreen.RINGTONE_PICKER -> SoundPickerScreen(
            title = stringResource(R.string.settings_ringtone),
            sounds = SoundLibrary.ringtones,
            currentId = chatViewModel.ringtoneId,
            onBack = { currentScreen = AppScreen.SETTINGS },
            onSelect = { id ->
                chatViewModel.ringtoneId = id
                chatViewModel.saveSettings()
                currentScreen = AppScreen.SETTINGS
            }
        )
    }
}

@Composable
fun MainScreen(
    chatViewModel: ChatViewModel,
    onOpenSettings: () -> Unit,
    onOpenContacts: () -> Unit
) {
    when (chatViewModel.screen) {
        ChatViewModel.Screen.WELCOME -> WelcomeScreen(
            privacyMode = chatViewModel.privacyMode,
            onPrivacyModeChange = {
                chatViewModel.privacyMode = it
                chatViewModel.saveSettings()
            },
            onCreateRoom = { chatViewModel.createRoom() },
            onJoinRoom = { chatViewModel.joinRoom(it) },
            onOpenSettings = onOpenSettings,
            onOpenContacts = onOpenContacts
        )

        ChatViewModel.Screen.WAITING -> WaitingScreen(
            roomId = chatViewModel.roomId ?: "",
            onCancel = { chatViewModel.leave() }
        )

        ChatViewModel.Screen.CONNECTING -> ConnectingScreen(
            onCancel = { chatViewModel.leave() }
        )

        ChatViewModel.Screen.CHAT -> ChatScreen(
            viewModel = chatViewModel,
            onOpenSettings = onOpenSettings,
            onLeave = { chatViewModel.leave() }
        )
    }
}

@Composable
fun WaitingScreen(roomId: String, onCancel: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        CircularProgressIndicator(color = GhostBlue, modifier = Modifier.size(48.dp))
        Spacer(modifier = Modifier.height(24.dp))
        Text(
            stringResource(R.string.waiting_title),
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
            color = GhostWhite
        )
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            stringResource(R.string.waiting_share_link),
            fontSize = 14.sp,
            color = GhostGray,
            textAlign = TextAlign.Center
        )
        Spacer(modifier = Modifier.height(16.dp))

        // Room link
        val link = "https://gbskgs.xyz/?room=$roomId"
        SelectionContainer {
            Text(
                text = link,
                fontSize = 12.sp,
                color = GhostBlue,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 24.dp)
            )
        }

        Spacer(modifier = Modifier.height(32.dp))
        TextButton(onClick = onCancel) {
            Text(stringResource(R.string.waiting_cancel), color = GhostRed)
        }
    }
}

@Composable
fun ConnectingScreen(onCancel: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        CircularProgressIndicator(color = GhostBlue, modifier = Modifier.size(48.dp))
        Spacer(modifier = Modifier.height(24.dp))
        Text(
            stringResource(R.string.connecting_title),
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
            color = GhostWhite
        )
        Spacer(modifier = Modifier.height(32.dp))
        TextButton(onClick = onCancel) {
            Text(stringResource(R.string.waiting_cancel), color = GhostRed)
        }
    }
}
