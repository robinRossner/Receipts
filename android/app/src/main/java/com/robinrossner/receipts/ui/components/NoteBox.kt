package com.robinrossner.receipts.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme

/** A coloured note with a leading icon (warnings, test results, flagged notice). [testTag] goes on the text. */
@Composable
fun NoteBox(icon: ImageVector, text: String, color: Color, background: Color, modifier: Modifier = Modifier, testTag: String? = null) {
    Row(
        modifier.fillMaxWidth().background(background, RoundedCornerShape(6.dp)).padding(10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, null, Modifier.size(16.dp), tint = color)
        Text(text, Modifier.let { if (testTag != null) it.testTag(testTag) else it }, style = AppTheme.body(13, color = color))
    }
}
