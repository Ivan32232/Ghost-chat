package com.kordar.ghostchat.features.settings

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kordar.ghostchat.BuildConfig
import com.kordar.ghostchat.R

private const val WEBSITE_URL = "https://ghostchat.one"
private const val PRIVACY_URL = "https://ghostchat.one/privacy"
private const val GITHUB_URL  = "https://github.com/Ivan32232/Ghost-chat"

@Composable
fun AboutScreen() {
    val ctx = LocalContext.current
    val openUrl: (String) -> Unit = { url ->
        runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(0.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(Modifier.size(20.dp))

        Icon(
            Icons.Outlined.Shield,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(56.dp)
        )
        Spacer(Modifier.size(12.dp))
        Text(
            stringResource(R.string.app_name),
            color = Color.White,
            fontSize = 24.sp,
            fontWeight = FontWeight.SemiBold
        )
        Text(
            "Version ${BuildConfig.VERSION_NAME} (build ${BuildConfig.VERSION_CODE})",
            color = Color.Gray,
            fontSize = 13.sp
        )
        Spacer(Modifier.size(6.dp))
        Text(
            "End-to-end encrypted. Zero-identity. Zero-retention.",
            color = Color.Gray,
            fontSize = 12.sp
        )

        Spacer(Modifier.size(32.dp))

        Column(modifier = Modifier.fillMaxWidth()) {
            LinkRow(
                label = stringResource(R.string.about_website),
                icon  = Icons.Outlined.Public,
                onClick = { openUrl(WEBSITE_URL) }
            )
            HorizontalDivider(color = Color.White.copy(alpha = 0.06f))
            LinkRow(
                label = stringResource(R.string.about_privacy_policy),
                icon  = Icons.Outlined.Lock,
                onClick = { openUrl(PRIVACY_URL) }
            )
            HorizontalDivider(color = Color.White.copy(alpha = 0.06f))
            LinkRow(
                label = stringResource(R.string.about_source_code),
                icon  = Icons.Outlined.Code,
                onClick = { openUrl(GITHUB_URL) }
            )
        }

        Spacer(Modifier.size(32.dp))

        Text(
            stringResource(R.string.about_made_by),
            color = Color.Gray,
            fontSize = 12.sp
        )
    }
}

@Composable
private fun LinkRow(label: String, icon: ImageVector, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(vertical = 16.dp)
    ) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
        Spacer(Modifier.size(14.dp))
        Text(label, color = Color.White, modifier = Modifier.weight(1f))
        Icon(
            Icons.Outlined.OpenInNew,
            contentDescription = null,
            tint = Color.Gray,
            modifier = Modifier.size(18.dp)
        )
    }
}
