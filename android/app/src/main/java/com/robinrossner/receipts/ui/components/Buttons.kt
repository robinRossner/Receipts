package com.robinrossner.receipts.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme

/**
 * The bordered button of the iPhone app (`Theme.OutlineButton`): at least 44dp high, 8dp corners, 14sp medium.
 * [fill] = solid `ink`; otherwise `paper` with a 1dp border of [color] at 45%. Wraps its content unless the caller adds `fillMaxWidth()`.
 */
@Composable
fun OutlineButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    color: Color = AppTheme.colors.ink,
    fill: Boolean = false,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    testTag: String? = null,
) {
    val c = AppTheme.colors
    val shape = RoundedCornerShape(AppTheme.corner)
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val content = if (fill) c.onInk else color
    Row(
        modifier
            .let { if (testTag != null) it.testTag(testTag) else it }
            .alpha(if (!enabled) 0.4f else if (pressed) 0.7f else 1f)
            .heightIn(min = 44.dp)
            .background(if (fill) c.ink else c.paper, shape)
            .let { if (fill) it else it.border(1.dp, color.copy(alpha = 0.45f), shape) }
            .clickable(interactionSource = source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, Modifier.size(18.dp), tint = content)
            Spacer(Modifier.width(6.dp))
        }
        Text(text, style = AppTheme.body(14, FontWeight.Medium, content), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** A 44x44 tap target around a small icon (`Theme.IconButton`). [contentDescription] is the iPhone accessibility label. */
@Composable
fun AppIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = AppTheme.colors.inkSoft,
    iconSize: Dp = 15.dp,
    enabled: Boolean = true,
) {
    Box(
        modifier.size(44.dp).alpha(if (enabled) 1f else 0.4f).clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription, Modifier.size(iconSize), tint = tint)
    }
}

/** A selectable pill (`Theme.Chip`): `ink` filled when [selected], else bordered `paper`. */
@Composable
fun AppChip(text: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val c = AppTheme.colors
    val shape = RoundedCornerShape(AppTheme.corner)
    Box(modifier.padding(vertical = 2.dp)) {
        Box(
            Modifier
                .heightIn(min = 36.dp)
                .background(if (selected) c.ink else c.paper, shape)
                .let { if (selected) it else it.border(1.dp, c.rule, shape) }
                .clickable(role = Role.Button, onClick = onClick)
                .semantics { this.selected = selected }
                .padding(horizontal = 12.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(text, style = AppTheme.body(14, if (selected) FontWeight.SemiBold else FontWeight.Normal, if (selected) c.onInk else c.ink), maxLines = 1)
        }
    }
}

/** An active filter with a remove cross (capsule). The hint "Removes this filter" is its click label. */
@Composable
fun FilterTag(text: String, onRemove: () -> Unit, modifier: Modifier = Modifier) {
    val c = AppTheme.colors
    Box(modifier.padding(vertical = 6.dp)) {
        Row(
            Modifier
                .heightIn(min = 32.dp)
                .background(c.paper, CircleShape)
                .border(1.dp, c.rule, CircleShape)
                .clickable(onClickLabel = "Removes this filter", role = Role.Button, onClick = onRemove)
                .padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text, style = AppTheme.body(13, FontWeight.Medium, c.ink), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.width(5.dp))
            Icon(Icons.Filled.Close, null, Modifier.size(10.dp), tint = c.ink)
        }
    }
}
