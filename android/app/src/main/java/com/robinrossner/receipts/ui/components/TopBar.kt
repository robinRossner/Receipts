package com.robinrossner.receipts.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.layoutId
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme

/**
 * True when a banner or the error bar above already paints the status bar area, so a top bar must not add its own inset.
 * Provided by `RootScreen`.
 */
val LocalStatusBarHandled = compositionLocalOf { false }

/**
 * The screen top bar on `paper` (replaces `CenterAlignedTopAppBar`): 56dp, title centred in the display font, 1dp `rule` below.
 * Tab roots use [titleSize] 20, pushed screens and sheets 18. The status-bar inset is added unless [topInset] is false or
 * [LocalStatusBarHandled] says a bar above has taken it. Back icon: `Icons.AutoMirrored.Filled.ArrowBack`, description "Back".
 */
@Composable
fun AppTopBar(
    title: String,
    modifier: Modifier = Modifier,
    titleSize: Float = 20f,
    navigationIcon: @Composable (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
    topInset: Boolean = true,
) {
    val c = AppTheme.colors
    Column(modifier.fillMaxWidth().background(c.paper)) {
        if (topInset && !LocalStatusBarHandled.current) Spacer(Modifier.windowInsetsTopHeight(WindowInsets.statusBars))
        Layout(
            content = {
                Box(Modifier.layoutId("nav"), contentAlignment = Alignment.CenterStart) { navigationIcon?.invoke() }
                Box(Modifier.layoutId("title"), contentAlignment = Alignment.Center) {
                    Text(title, style = AppTheme.display(titleSize, c.ink), maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                }
                Row(Modifier.layoutId("actions"), verticalAlignment = Alignment.CenterVertically, content = actions)
            },
            modifier = Modifier.fillMaxWidth().height(56.dp),
        ) { measurables, constraints ->
            val loose = constraints.copy(minWidth = 0, minHeight = 0)
            val nav = measurables.first { it.layoutId == "nav" }.measure(loose)
            val act = measurables.first { it.layoutId == "actions" }.measure(loose)
            // The same width on both sides keeps the title centred.
            val side = maxOf(nav.width, act.width, 8.dp.roundToPx())
            val titleWidth = (constraints.maxWidth - 2 * side).coerceAtLeast(0)
            val titleP = measurables.first { it.layoutId == "title" }.measure(Constraints(maxWidth = titleWidth, maxHeight = constraints.maxHeight))
            layout(constraints.maxWidth, constraints.maxHeight) {
                nav.placeRelative(0, (constraints.maxHeight - nav.height) / 2)
                act.placeRelative(constraints.maxWidth - act.width, (constraints.maxHeight - act.height) / 2)
                titleP.placeRelative(side + (titleWidth - titleP.width) / 2, (constraints.maxHeight - titleP.height) / 2)
            }
        }
        RuleDivider()
    }
}
