package com.robinrossner.receipts.ui.components

import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.FlowRowScope
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.robinrossner.receipts.ui.theme.AppTheme

/** A sheet of paper on the desk: `paper` fill, 1dp `rule` border, 8dp corners, then the inner padding (`Theme.paperCard`). */
@Composable
fun Modifier.paperCard(padding: Dp = 14.dp): Modifier {
    val shape = RoundedCornerShape(AppTheme.corner)
    return this.background(AppTheme.colors.paper, shape).border(1.dp, AppTheme.colors.rule, shape).padding(padding)
}

/** The box behind a text field or picker: `field` fill, 6dp corners, 1dp border (`ink` while [focused]). No padding of its own. */
@Composable
fun Modifier.fieldBox(focused: Boolean = false): Modifier {
    val shape = RoundedCornerShape(6.dp)
    val c = AppTheme.colors
    return this.background(c.field, shape).border(1.dp, if (focused) c.ink else c.rule, shape)
}

/** Small uppercase heading above a group (`Theme.SectionLabel`). */
@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(), modifier = modifier,
        style = AppTheme.body(11, FontWeight.SemiBold, AppTheme.colors.label).copy(letterSpacing = 0.6.sp),
    )
}

/** 1dp horizontal `rule` line; [alpha] 0.5 is the divider inside item groups. */
@Composable
fun RuleDivider(modifier: Modifier = Modifier, alpha: Float = 1f) {
    androidx.compose.foundation.layout.Box(modifier.fillMaxWidth().height(1.dp).background(AppTheme.colors.rule.copy(alpha = alpha)))
}

@Composable
fun RuleDividerVertical(modifier: Modifier = Modifier, alpha: Float = 1f) {
    androidx.compose.foundation.layout.Box(modifier.fillMaxHeight().width(1.dp).background(AppTheme.colors.rule.copy(alpha = alpha)))
}

/** Mini spinner (12dp). "Small" is 16dp / 2dp stroke, "large" 36dp: pass [size] and [strokeWidth] (16.dp, 2.dp). */
@Composable
fun MiniSpinner(size: Dp = 12.dp, color: Color = AppTheme.colors.inkSoft, strokeWidth: Dp = 1.5.dp, modifier: Modifier = Modifier) {
    CircularProgressIndicator(modifier.size(size), color = color, strokeWidth = strokeWidth)
}

/** Wrapping row with the same spacing both ways (`FlowLayout(spacing:)`). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AppFlowRow(
    horizontalSpacing: Dp,
    verticalSpacing: Dp = horizontalSpacing,
    modifier: Modifier = Modifier,
    content: @Composable FlowRowScope.() -> Unit,
) {
    FlowRow(modifier, horizontalArrangement = Arrangement.spacedBy(horizontalSpacing), verticalArrangement = Arrangement.spacedBy(verticalSpacing), content = content)
}
