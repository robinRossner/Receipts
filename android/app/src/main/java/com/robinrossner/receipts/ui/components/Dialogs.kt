package com.robinrossner.receipts.ui.components

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import com.robinrossner.receipts.ui.theme.AppTheme

/** Confirmation with a Cancel button (the iPhone's confirmation dialogs). [destructive] paints the confirm text `red`. */
@Composable
fun AppConfirmDialog(
    title: String,
    message: String?,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    destructive: Boolean = false,
    dismissLabel: String = "Cancel",
    confirmTestTag: String? = null,
) {
    val c = AppTheme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = c.paper,
        title = { Text(title, style = AppTheme.body(17, FontWeight.SemiBold, c.ink)) },
        text = message?.let { { Text(it, style = AppTheme.body(14, color = c.inkSoft)) } },
        confirmButton = {
            TextButton(onClick = onConfirm, modifier = if (confirmTestTag != null) Modifier.testTag(confirmTestTag) else Modifier) {
                Text(confirmLabel, style = AppTheme.body(14, FontWeight.Medium, if (destructive) c.red else c.ink))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(dismissLabel, style = AppTheme.body(14, FontWeight.Medium, c.ink)) } },
    )
}

/** A message with a single OK (the iPhone's `.alert`). */
@Composable
fun AppAlertDialog(title: String, message: String?, onDismiss: () -> Unit) {
    val c = AppTheme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = c.paper,
        title = { Text(title, style = AppTheme.body(17, FontWeight.SemiBold, c.ink)) },
        text = message?.let { { Text(it, style = AppTheme.body(14, color = c.inkSoft)) } },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK", style = AppTheme.body(14, FontWeight.Medium, c.ink)) } },
    )
}
