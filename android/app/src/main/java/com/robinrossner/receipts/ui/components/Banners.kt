package com.robinrossner.receipts.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme

/**
 * One server warning (`archive_overdue`, `disk_warning`) across the top, with a "Sync now" button. When [topInset] is true it also
 * paints the status-bar area in its own colour. Tagged `syncBanner`.
 */
@Composable
fun SyncBanner(text: String, syncing: Boolean, onSyncNow: () -> Unit, topInset: Boolean, modifier: Modifier = Modifier) {
    val c = AppTheme.colors
    Column(modifier.fillMaxWidth().background(c.redBg).testTag("syncBanner")) {
        if (topInset) Spacer(Modifier.windowInsetsTopHeight(WindowInsets.statusBars))
        Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Storage, null, Modifier.size(16.dp), tint = c.red)
            Text(text, Modifier.weight(1f), style = AppTheme.body(12.5f, color = c.red))
            OutlineButton("Sync now", onClick = onSyncNow, color = c.red, enabled = !syncing)
        }
        RuleDivider(alpha = 0.3f)
    }
}

/** The red bar for a failed store action; stays until dismissed. White content in both modes. */
@Composable
fun ErrorBar(message: String, onDismiss: () -> Unit, topInset: Boolean, modifier: Modifier = Modifier) {
    val c = AppTheme.colors
    Column(modifier.fillMaxWidth().background(c.errorBar).testTag("errorBar")) {
        if (topInset) Spacer(Modifier.windowInsetsTopHeight(WindowInsets.statusBars))
        Row(Modifier.fillMaxWidth().padding(start = 14.dp, end = 2.dp), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Warning, null, Modifier.size(13.dp), tint = Color.White)
            Text(message, Modifier.weight(1f).padding(vertical = 8.dp), style = AppTheme.body(13, FontWeight.Medium, Color.White))
            AppIconButton(Icons.Filled.Close, "Dismiss", onDismiss, tint = Color.White, iconSize = 13.dp)
        }
    }
}
