package com.robinrossner.receipts.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme

/*
 * Old component names, kept only so the screens that have not been ported yet still compile (each now draws with the new
 * look). Do not use them in new code. Delete this file once ui/screens no longer imports any of them.
 */

/** Use `Modifier.paperCard()`. */
@Composable
fun Paper(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Surface(modifier = modifier, color = AppTheme.colors.paper, shape = RoundedCornerShape(AppTheme.corner), border = BorderStroke(1.dp, AppTheme.colors.rule), content = content)
}

/** Use `OutlineButton(fill = true)`. */
@Composable
fun InkButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    OutlineButton(text, onClick, modifier, fill = true, enabled = enabled)
}

/** Use `OutlineButton(color = ...)`. */
@Composable
fun QuietButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, danger: Boolean = false, onClick: () -> Unit) {
    OutlineButton(text, onClick, modifier, color = if (danger) AppTheme.colors.red else AppTheme.colors.ink, enabled = enabled)
}

/** Use `NoteBox`. */
@Composable
fun PenBox(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(
        modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).background(AppTheme.colors.redBg)
            .border(1.dp, AppTheme.colors.red, RoundedCornerShape(6.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) { content() }
}

/** The Settings rows are redone in the settings screen; do not use. */
@Composable
fun LabelValueRow(label: String, modifier: Modifier = Modifier, value: @Composable () -> Unit) {
    Row(modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = AppTheme.body(14, color = AppTheme.colors.inkSoft))
        value()
    }
}
