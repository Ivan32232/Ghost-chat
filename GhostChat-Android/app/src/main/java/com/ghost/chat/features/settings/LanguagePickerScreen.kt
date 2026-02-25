package com.ghost.chat.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghost.chat.R
import com.ghost.chat.core.localization.LocalizationManager
import com.ghost.chat.ui.theme.*

@Composable
fun LanguagePickerScreen(
    onBack: () -> Unit,
    onLanguageSelected: (String) -> Unit
) {
    val currentLanguage = LocalizationManager.currentLanguage

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(GhostBlack)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(GhostSurface)
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = GhostBlue)
            }
            Text(
                stringResource(R.string.settings_language),
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                color = GhostWhite
            )
        }

        Card(
            modifier = Modifier.padding(16.dp),
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = GhostSurface)
        ) {
            Column {
                LanguageRow("English", "en", currentLanguage == "en") {
                    onLanguageSelected("en")
                }
                HorizontalDivider(color = GhostGrayLight, thickness = 0.5.dp)
                LanguageRow("Русский", "ru", currentLanguage == "ru") {
                    onLanguageSelected("ru")
                }
            }
        }
    }
}

@Composable
private fun LanguageRow(
    title: String,
    code: String,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(title, fontSize = 16.sp, color = GhostWhite)
        if (isSelected) {
            Icon(Icons.Default.Check, contentDescription = null, tint = GhostBlue)
        }
    }
}
