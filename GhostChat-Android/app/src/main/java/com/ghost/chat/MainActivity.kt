package com.ghost.chat

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.ui.graphics.Color
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.ghost.chat.core.audio.SoundLibrary
import com.ghost.chat.core.localization.LocalizationManager
import com.ghost.chat.core.security.BiometricAuthService
import com.ghost.chat.core.security.SecurityMonitor
import com.ghost.chat.features.chat.ChatScreen
import com.ghost.chat.features.chat.ChatViewModel
import com.ghost.chat.features.contacts.ContactsScreen
import com.ghost.chat.features.contacts.ContactsViewModel
import com.ghost.chat.features.settings.LanguagePickerScreen
import com.ghost.chat.features.settings.LockScreen
import com.ghost.chat.features.settings.SettingsScreen
import com.ghost.chat.features.settings.SoundPickerScreen
import com.ghost.chat.features.welcome.WelcomeScreen
import com.ghost.chat.ui.theme.*

// ViewModelProvider.Factory for ViewModels that require applicationContext
class ChatViewModelFactory(private val context: Context) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        return ChatViewModel(context.applicationContext) as T
    }
}

class ContactsViewModelFactory(private val context: Context) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        return ContactsViewModel(context.applicationContext) as T
    }
}

class MainActivity : FragmentActivity() {

    private lateinit var chatViewModel: ChatViewModel
    private lateinit var contactsViewModel: ContactsViewModel

    // Runtime permission for RECORD_AUDIO (calls)
    private var pendingMicGranted: (() -> Unit)? = null
    private val micPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) pendingMicGranted?.invoke()
        pendingMicGranted = null
    }

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(LocalizationManager.applyLocale(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Apply FLAG_SECURE (prevent screenshots/recording)
        SecurityMonitor.applyFlagSecure(this)

        // Use ViewModelProvider so ViewModel survives configuration changes
        chatViewModel = ViewModelProvider(this, ChatViewModelFactory(applicationContext))[ChatViewModel::class.java]
        contactsViewModel = ViewModelProvider(this, ContactsViewModelFactory(applicationContext))[ContactsViewModel::class.java]

        // Wire up RECORD_AUDIO permission request
        chatViewModel.onRequestMicPermission = { onGranted ->
            pendingMicGranted = onGranted
            micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }

        // Provide Activity reference for screen capture detection (API 34+)
        chatViewModel.setActivity(this)

        // Handle deep link
        handleIntent(intent)

        setContent {
            // Request POST_NOTIFICATIONS permission on Android 13+ (API 33)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val notificationPermissionLauncher = rememberLauncherForActivityResult(
                    ActivityResultContracts.RequestPermission()
                ) { /* granted or denied — no action needed, system handles it */ }

                LaunchedEffect(Unit) {
                    if (ContextCompat.checkSelfPermission(
                            this@MainActivity,
                            Manifest.permission.POST_NOTIFICATIONS
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }
            }

            // Request RECORD_AUDIO permission on first launch (for voice calls)
            val micPermissionLauncherStartup = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission()
            ) { /* granted or denied */ }

            LaunchedEffect(Unit) {
                if (ContextCompat.checkSelfPermission(
                        this@MainActivity,
                        Manifest.permission.RECORD_AUDIO
                    ) != PackageManager.PERMISSION_GRANTED
                ) {
                    // Small delay to not overlap with notification permission dialog
                    delay(1500)
                    micPermissionLauncherStartup.launch(Manifest.permission.RECORD_AUDIO)
                }
            }

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

    /** Validate room ID format: base64url, exactly 64 chars */
    private fun isValidRoomId(id: String): Boolean {
        return id.matches(Regex("^[A-Za-z0-9_-]{64}$"))
    }

    private fun handleIntent(intent: Intent?) {
        intent ?: return

        // Handle push notification extras (from NotificationHelper intents)
        val extras = intent.extras
        if (extras != null) {
            // Incoming call push — show pending incoming call (require user confirmation)
            if (extras.getBoolean("incoming_call", false)) {
                val roomId = extras.getString("room_id")
                if (roomId != null && isValidRoomId(roomId)) {
                    chatViewModel.handleDeepLink(roomId)
                    return
                }
            }

            // Chat invite push — show deep link dialog
            val inviteRoomId = extras.getString("invite_room_id")
            if (inviteRoomId != null && isValidRoomId(inviteRoomId)) {
                chatViewModel.handleDeepLink(inviteRoomId)
                return
            }

            // Message push — navigate to contact's chat by sender name
            val messageSender = extras.getString("message_sender")
            if (messageSender != null) {
                chatViewModel.handleMessagePushTap(messageSender)
                return
            }

            // Missed call push — navigate to contact's chat by caller name
            val missedCallFrom = extras.getString("missed_call_from")
            if (missedCallFrom != null) {
                chatViewModel.handleMessagePushTap(missedCallFrom)
                return
            }
        }

        // Handle URI deep links
        val data = intent.data ?: return

        // Handle: https://ghostchat.one/?room=ROOM_ID
        val roomId = data.getQueryParameter("room")
        if (roomId != null && isValidRoomId(roomId)) {
            chatViewModel.handleDeepLink(roomId)
            return
        }

        // Handle: ghostchat://room/ROOM_ID
        if (data.scheme == "ghostchat") {
            val pathRoom = data.pathSegments.firstOrNull()
            if (pathRoom != null && isValidRoomId(pathRoom)) {
                chatViewModel.handleDeepLink(pathRoom)
            }
        }
    }

    override fun onPause() {
        super.onPause()
        // Don't lock during active call (matches iOS behavior)
        if (chatViewModel.callState == ChatViewModel.CallUIState.IDLE) {
            BiometricAuthService.didEnterBackground()
        }
    }

    override fun onResume() {
        super.onResume()
        // Check auto-lock timer on return
        if (chatViewModel.callState == ChatViewModel.CallUIState.IDLE) {
            BiometricAuthService.didEnterForeground()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        SoundLibrary.stopPreview()
        // ViewModel is managed by ViewModelProvider — onCleared() fires automatically
        // when the Activity is finishing. No explicit leave() needed.
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

    // isUnlocked is Compose mutableStateOf — changes trigger recomposition automatically.
    // isPinSet / isEnabled are computed from KeystoreService each read.
    val needsLock = (BiometricAuthService.isPinSet || BiometricAuthService.isEnabled)
            && !BiometricAuthService.isUnlocked

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        GhostChatContent(
            currentScreen = currentScreen,
            onScreenChange = { currentScreen = it },
            chatViewModel = chatViewModel,
            contactsViewModel = contactsViewModel,
            onLanguageChanged = onLanguageChanged
        )

        // PIN / Biometric lock overlay
        if (needsLock) {
            LockScreen(onUnlocked = {
                // verifyPin() / authenticate() already set isUnlocked = true,
                // but keep callback as safety net for recomposition
            })
        }
    }
}

@Composable
private fun GhostChatContent(
    currentScreen: AppScreen,
    onScreenChange: (AppScreen) -> Unit,
    chatViewModel: ChatViewModel,
    contactsViewModel: ContactsViewModel,
    onLanguageChanged: () -> Unit
) {
    when (currentScreen) {
        AppScreen.MAIN -> MainScreen(
            chatViewModel = chatViewModel,
            contactsViewModel = contactsViewModel,
            onOpenSettings = { onScreenChange(AppScreen.SETTINGS) },
            onOpenContacts = { onScreenChange(AppScreen.CONTACTS) }
        )

        AppScreen.SETTINGS -> SettingsScreen(
            viewModel = chatViewModel,
            onBack = { onScreenChange(AppScreen.MAIN) },
            onLanguagePicker = { onScreenChange(AppScreen.LANGUAGE_PICKER) },
            onSoundPicker = { onScreenChange(AppScreen.SOUND_PICKER) },
            onRingtonePicker = { onScreenChange(AppScreen.RINGTONE_PICKER) }
        )

        AppScreen.CONTACTS -> ContactsScreen(
            viewModel = contactsViewModel,
            onBack = { onScreenChange(AppScreen.MAIN) },
            onStartChat = { contact ->
                chatViewModel.startChatWithContact(contact)
                onScreenChange(AppScreen.MAIN)
            }
        )

        AppScreen.LANGUAGE_PICKER -> {
            val context = LocalContext.current
            LanguagePickerScreen(
                onBack = { onScreenChange(AppScreen.SETTINGS) },
                onLanguageSelected = { lang ->
                    LocalizationManager.setLanguage(lang, context)
                    onLanguageChanged()
                }
            )
        }

        AppScreen.SOUND_PICKER -> {
            val ctx = LocalContext.current
            SoundPickerScreen(
                title = stringResource(R.string.settings_msg_sound),
                sounds = SoundLibrary.messageSoundOptions(ctx),
                currentId = chatViewModel.messageSoundId,
                onBack = { onScreenChange(AppScreen.SETTINGS) },
                onSelect = { id ->
                    chatViewModel.messageSoundId = id
                    chatViewModel.saveSettings()
                    onScreenChange(AppScreen.SETTINGS)
                }
            )
        }

        AppScreen.RINGTONE_PICKER -> {
            val ctx = LocalContext.current
            SoundPickerScreen(
                title = stringResource(R.string.settings_ringtone),
                sounds = SoundLibrary.ringtoneOptions(ctx),
                currentId = chatViewModel.ringtoneId,
                onBack = { onScreenChange(AppScreen.SETTINGS) },
                onSelect = { id ->
                    chatViewModel.ringtoneId = id
                    chatViewModel.saveSettings()
                    onScreenChange(AppScreen.SETTINGS)
                },
                onPreview = { c, id -> SoundLibrary.previewRingtone(c, id) }
            )
        }
    }
}

@Composable
fun MainScreen(
    chatViewModel: ChatViewModel,
    contactsViewModel: ContactsViewModel? = null,
    onOpenSettings: () -> Unit,
    onOpenContacts: () -> Unit
) {
    // Load contacts when returning to welcome screen
    LaunchedEffect(chatViewModel.screen) {
        if (chatViewModel.screen == ChatViewModel.Screen.WELCOME) {
            contactsViewModel?.loadContacts()
        }
    }

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
            onOpenContacts = onOpenContacts,
            contacts = contactsViewModel?.contacts ?: emptyList(),
            lastMessages = contactsViewModel?.lastMessages ?: emptyMap(),
            unreadCounts = contactsViewModel?.unreadCounts ?: emptyMap(),
            onContactClick = { contact ->
                chatViewModel.startChatWithContact(contact)
            },
            onDeleteContact = { contact ->
                contactsViewModel?.deleteContact(contact)
            },
            onOpenSavedMessages = if (chatViewModel.savedMessagesEnabled) {
                { chatViewModel.openSavedMessages() }
            } else null,
            savedMessagesLastMessage = contactsViewModel?.lastMessages?.get(
                ChatViewModel.SAVED_MESSAGES_CONTACT_ID
            )
        )

        ChatViewModel.Screen.WAITING -> WaitingScreen(
            roomId = chatViewModel.roomId ?: "",
            onCancel = { chatViewModel.leave() }
        )

        ChatViewModel.Screen.CONNECTING -> ConnectingScreen(
            connectionStep = chatViewModel.connectionStep,
            onCancel = { chatViewModel.leave() }
        )

        ChatViewModel.Screen.CHAT -> {
            var showContactDetail by remember { mutableStateOf(false) }
            var detailContact by remember { mutableStateOf<com.ghost.chat.models.Contact?>(null) }

            if (showContactDetail && detailContact != null) {
                com.ghost.chat.features.contacts.ContactDetailScreen(
                    contact = detailContact!!,
                    viewModel = contactsViewModel ?: return,
                    onStartChat = { showContactDetail = false },
                    onBack = { showContactDetail = false }
                )
            } else {
                ChatScreen(
                    viewModel = chatViewModel,
                    onOpenSettings = onOpenSettings,
                    onLeave = {
                        if (chatViewModel.isConnected) chatViewModel.navigateBack()
                        else chatViewModel.leave()
                    },
                    onContactClick = { contact ->
                        detailContact = contact
                        showContactDetail = true
                    }
                )
            }
        }
    }
}

@Composable
fun WaitingScreen(roomId: String, onCancel: () -> Unit) {
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }
    val link = "https://ghostchat.one/?room=$roomId"

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        CircularProgressIndicator(color = GhostAccent, modifier = Modifier.size(48.dp))
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
        SelectionContainer {
            Text(
                text = link,
                fontSize = 12.sp,
                color = GhostAccent,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 24.dp)
            )
        }

        Spacer(modifier = Modifier.height(20.dp))

        // Copy + Share buttons
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(horizontal = 24.dp)
        ) {
            // Copy button
            Button(
                onClick = {
                    clipboardManager.setText(AnnotatedString(link))
                    copied = true
                    scope.launch {
                        delay(2000)
                        copied = false
                    }
                },
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (copied) GhostGreen else GhostSurfaceLight
                ),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.weight(1f).height(48.dp)
            ) {
                Icon(
                    Icons.Default.ContentCopy,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = GhostWhite
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    if (copied) "Скопировано!" else "Копировать",
                    color = GhostWhite,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }

            // Share button
            Button(
                onClick = {
                    val shareIntent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, link)
                    }
                    context.startActivity(Intent.createChooser(shareIntent, null))
                },
                colors = ButtonDefaults.buttonColors(containerColor = GhostAccent, contentColor = GhostBlack),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.weight(1f).height(48.dp)
            ) {
                Icon(
                    Icons.Default.Share,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = GhostBlack
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    "Поделиться",
                    color = GhostBlack,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }

        Spacer(modifier = Modifier.height(32.dp))
        TextButton(onClick = onCancel) {
            Text(stringResource(R.string.waiting_cancel), color = GhostRed)
        }
    }
}

@Composable
fun ConnectingScreen(
    connectionStep: ChatViewModel.ConnectionStep = ChatViewModel.ConnectionStep.CONNECTING_TO_SERVER,
    onCancel: () -> Unit
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            // Animated shield icon — changes per step
            val shieldIcon = when (connectionStep) {
                ChatViewModel.ConnectionStep.CONNECTING_TO_SERVER -> Icons.Default.Shield
                ChatViewModel.ConnectionStep.WAITING_FOR_PEER -> Icons.Default.Shield
                ChatViewModel.ConnectionStep.EXCHANGING_KEYS -> Icons.Default.Lock
                ChatViewModel.ConnectionStep.SECURED -> Icons.Default.VerifiedUser
            }
            val shieldColor = when (connectionStep) {
                ChatViewModel.ConnectionStep.CONNECTING_TO_SERVER -> GhostGray
                ChatViewModel.ConnectionStep.WAITING_FOR_PEER -> GhostWhite.copy(alpha = 0.7f)
                ChatViewModel.ConnectionStep.EXCHANGING_KEYS -> Color(1.0f, 0.85f, 0.35f) // gold
                ChatViewModel.ConnectionStep.SECURED -> GhostGreen
            }

            Icon(
                imageVector = shieldIcon,
                contentDescription = null,
                tint = shieldColor,
                modifier = Modifier.size(64.dp)
            )

            Spacer(modifier = Modifier.height(32.dp))

            // Connection steps
            Column(
                modifier = Modifier
                    .padding(horizontal = 32.dp)
                    .background(
                        color = Color.White.copy(alpha = 0.05f),
                        shape = RoundedCornerShape(16.dp)
                    )
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                ConnectionStepRow(
                    icon = Icons.Default.Link,
                    text = stringResource(R.string.connecting_step_server),
                    state = stepState(ChatViewModel.ConnectionStep.CONNECTING_TO_SERVER, connectionStep)
                )
                ConnectionStepRow(
                    icon = Icons.Default.People,
                    text = stringResource(R.string.connecting_step_peer),
                    state = stepState(ChatViewModel.ConnectionStep.WAITING_FOR_PEER, connectionStep)
                )
                ConnectionStepRow(
                    icon = Icons.Default.Lock,
                    text = stringResource(R.string.connecting_step_keys),
                    state = stepState(ChatViewModel.ConnectionStep.EXCHANGING_KEYS, connectionStep)
                )
                ConnectionStepRow(
                    icon = Icons.Default.VerifiedUser,
                    text = stringResource(R.string.connecting_step_secured),
                    state = stepState(ChatViewModel.ConnectionStep.SECURED, connectionStep)
                )
            }

            Spacer(modifier = Modifier.height(32.dp))

            TextButton(onClick = onCancel) {
                Text(stringResource(R.string.waiting_cancel), color = GhostRed)
            }
        }
    }
}

private fun stepState(
    target: ChatViewModel.ConnectionStep,
    current: ChatViewModel.ConnectionStep
): StepState {
    val t = target.ordinal
    val c = current.ordinal
    return when {
        t < c -> StepState.DONE
        t == c -> StepState.ACTIVE
        else -> StepState.PENDING
    }
}

private enum class StepState { PENDING, ACTIVE, DONE }

@Composable
private fun ConnectionStepRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    text: String,
    state: StepState
) {
    val iconColor = when (state) {
        StepState.DONE -> GhostGreen
        StepState.ACTIVE -> GhostAccent
        StepState.PENDING -> GhostGray.copy(alpha = 0.5f)
    }
    val textColor = when (state) {
        StepState.DONE -> GhostWhite
        StepState.ACTIVE -> GhostWhite
        StepState.PENDING -> GhostGray.copy(alpha = 0.5f)
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = iconColor,
            modifier = Modifier.size(20.dp)
        )
        Spacer(modifier = Modifier.width(12.dp))
        Text(
            text = text,
            fontSize = 14.sp,
            fontWeight = if (state == StepState.ACTIVE) FontWeight.SemiBold else FontWeight.Normal,
            color = textColor,
            modifier = Modifier.weight(1f)
        )
        when (state) {
            StepState.DONE -> Icon(
                imageVector = Icons.Default.CheckCircle,
                contentDescription = null,
                tint = GhostGreen,
                modifier = Modifier.size(20.dp)
            )
            StepState.ACTIVE -> CircularProgressIndicator(
                color = GhostAccent,
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp)
            )
            StepState.PENDING -> Icon(
                imageVector = Icons.Default.RadioButtonUnchecked,
                contentDescription = null,
                tint = GhostGray.copy(alpha = 0.3f),
                modifier = Modifier.size(20.dp)
            )
        }
    }
}
