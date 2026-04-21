package com.kordar.ghostchat.features.settings

import androidx.lifecycle.ViewModel
import com.kordar.ghostchat.core.localization.LocalizationManager
import com.kordar.ghostchat.core.managers.ContactManager
import com.kordar.ghostchat.core.managers.SettingsManager
import com.kordar.ghostchat.core.security.BiometricAuthService
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject

@HiltViewModel
class SettingsViewModel @Inject constructor(
    val settings: SettingsManager,
    val localization: LocalizationManager,
    val contacts: ContactManager,
    val auth: BiometricAuthService
) : ViewModel()
