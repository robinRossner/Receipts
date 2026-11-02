package com.robinrossner.receipts.ui.list

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.ui.components.MiniSpinner
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.processing
import com.robinrossner.receipts.ui.theme.AppTheme

/**
 * A receipt row with the iPhone's swipe actions: right = "Looks good" (only when allowed), left = "Delete".
 * The row always snaps back; the data change moves or removes it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SwipeableReceiptRow(
    r: ReceiptSummary,
    reasons: Map<String, List<String>>,
    onOpen: (String) -> Unit,
    onConfirm: (ReceiptSummary) -> Unit,
    onDelete: (ReceiptSummary) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    val shape = RoundedCornerShape(AppTheme.corner)
    val canConfirm = ListLogic.canConfirmBySwipe(r)
    val current by rememberUpdatedState(r)
    val confirm by rememberUpdatedState(onConfirm)
    val delete by rememberUpdatedState(onDelete)
    val state = rememberSwipeToDismissBoxState(
        positionalThreshold = { it * 0.5f },
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.StartToEnd -> { if (ListLogic.canConfirmBySwipe(current)) confirm(current); false }
                SwipeToDismissBoxValue.EndToStart -> { delete(current); false }
                SwipeToDismissBoxValue.Settled -> true
            }
        },
    )
    SwipeToDismissBox(
        state = state,
        modifier = modifier,
        enableDismissFromStartToEnd = canConfirm,
        enableDismissFromEndToStart = true,
        backgroundContent = {
            val direction = state.dismissDirection
            if (direction == SwipeToDismissBoxValue.Settled) {
                Box(Modifier.fillMaxSize())
            } else {
                val confirming = direction == SwipeToDismissBoxValue.StartToEnd
                Box(
                    Modifier.fillMaxSize().clip(shape).background(if (confirming) colors.green else colors.red).padding(horizontal = 20.dp),
                    contentAlignment = if (confirming) Alignment.CenterStart else Alignment.CenterEnd,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(if (confirming) Icons.Filled.Check else Icons.Outlined.Delete, null, Modifier.size(18.dp), tint = Color.White)
                        Text(if (confirming) "Looks good" else "Delete", style = AppTheme.body(13, FontWeight.SemiBold, Color.White))
                    }
                }
            }
        },
    ) {
        ReceiptRow(r, reasons, canConfirm, { onOpen(r.uuid) }, { onConfirm(r) }, { onDelete(r) })
    }
}

@Composable
fun ReceiptRow(
    r: ReceiptSummary,
    reasons: Map<String, List<String>>,
    canConfirm: Boolean,
    onClick: () -> Unit,
    onConfirm: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = AppTheme.colors
    val shape = RoundedCornerShape(AppTheme.corner)
    val unreviewed = r.reviewedAt == null
    val processing = r.processing
    val warning = ListLogic.inlineWarning(r, reasons)
    val barWidth = 4.dp
    Box(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 58.dp)
            .clip(shape)
            .background(colors.paper)
            .drawBehind { if (unreviewed) drawRect(colors.red, size = Size(barWidth.toPx(), size.height)) }
            .border(1.dp, colors.rule, shape)
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) {
                customActions = buildList {
                    if (canConfirm) add(CustomAccessibilityAction("Looks good") { onConfirm(); true })
                    add(CustomAccessibilityAction("Delete") { onDelete(); true })
                }
            }
            .testTag("receiptRow"),
        contentAlignment = Alignment.CenterStart,
    ) {
        Row(
            Modifier.fillMaxWidth().padding(start = 14.dp, end = 12.dp, top = 11.dp, bottom = 11.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(Modifier.weight(1f).alignByBaseline(), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(ListLogic.rowName(r), style = AppTheme.body(16, FontWeight.SemiBold, colors.ink), maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (processing != null) {
                    val tint = if (processing.isActive) colors.inkSoft else colors.red
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        if (processing.isActive) MiniSpinner(12.dp, tint) else Icon(Icons.Filled.Error, null, Modifier.size(12.dp), tint = tint)
                        Text(processing.label, style = AppTheme.body(13, color = tint), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(r.date ?: "", style = AppTheme.mono(12, color = colors.inkSoft))
                        if (ListLogic.showsWarningIcon(r)) Icon(Icons.Filled.Warning, "Has warnings", Modifier.size(10.dp), tint = colors.red)
                    }
                }
                if (warning != null) {
                    Row(Modifier.padding(top = 1.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(Icons.Filled.Warning, null, Modifier.size(10.dp), tint = colors.red)
                        Text(warning, style = AppTheme.body(12.5f, color = colors.red), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            if (ListLogic.showsTotal(r)) {
                Text(fmtMoney(r.total), Modifier.alignByBaseline(), style = AppTheme.mono(15, FontWeight.Medium, colors.ink))
            }
        }
    }
}
