package com.robinrossner.receipts.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.ReviewQueue
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.ui.DetailViewModel
import com.robinrossner.receipts.ui.ListUi
import com.robinrossner.receipts.ui.components.AppConfirmDialog
import com.robinrossner.receipts.ui.components.AppIconButton
import com.robinrossner.receipts.ui.components.AppTopBar
import com.robinrossner.receipts.ui.components.LocalErrorCenter
import com.robinrossner.receipts.ui.components.LocalSnackCenter
import com.robinrossner.receipts.ui.components.MiniSpinner
import com.robinrossner.receipts.ui.components.RuleDivider
import com.robinrossner.receipts.ui.components.SegmentedControl
import com.robinrossner.receipts.ui.components.SnackbarBar
import com.robinrossner.receipts.ui.detail.DetailLogic
import com.robinrossner.receipts.ui.detail.ItemsTab
import com.robinrossner.receipts.ui.detail.PhotoTab
import com.robinrossner.receipts.ui.processing
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.launch

/**
 * One receipt (`ReceiptDetailScreen.swift`): the Items tab (header, item rows, add form, totals) and the Photo tab, with the review bar
 * at the bottom. "Looks good" confirms and moves on to the next receipt to review, in place ([onNext]); with none left it goes [onBack].
 * [highlightItemId]: a dictionary id from the Overview's `Edit` or a Flagged link; that item group opens, scrolls into view and is tinted.
 */
@Composable
fun ReceiptDetailScreen(
    container: AppContainer, vm: DetailViewModel, list: ListUi, onBack: () -> Unit, onNext: (String) -> Unit, highlightItemId: String? = null,
) {
    val receipt by vm.receipt.collectAsStateWithLifecycle()
    val loaded by vm.loaded.collectAsStateWithLifecycle()
    val items by vm.items.collectAsStateWithLifecycle()
    val photo by vm.photo.collectAsStateWithLifecycle()
    val busy by vm.busy.collectAsStateWithLifecycle()
    val colors = AppTheme.colors
    val snacks = LocalSnackCenter.current
    val errors = LocalErrorCenter.current
    var photoTab by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var confirmRerun by remember { mutableStateOf(false) }
    val tabs = rememberSaveableStateHolder()

    LaunchedEffect(vm.uuid, receipt?.extractionStatus, receipt?.photoLocation) { vm.ensurePhoto() }
    // A receipt that was deleted (here or by sync) leaves the screen.
    val gone = loaded && (receipt == null || receipt?.deletedAt != null)
    LaunchedEffect(gone) { if (gone) onBack() }

    val r = receipt
    Column(Modifier.fillMaxSize().background(colors.desk)) {
        AppTopBar(
            title = r?.store ?: "Receipt", titleSize = 18f,
            navigationIcon = { AppIconButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", onBack, tint = colors.ink, iconSize = 24.dp) },
        )
        if (r == null) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { MiniSpinner(36.dp, strokeWidth = 3.dp) }
        } else {
            SegmentedControl(
                listOf("Items", "Photo"), if (photoTab) 1 else 0, { photoTab = it == 1 },
                Modifier.padding(horizontal = 14.dp, vertical = 8.dp), testTags = listOf("tab_Items", "tab_Photo"),
            )
            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (photoTab) PhotoTab(container, photo)
                else tabs.SaveableStateProvider("items") {
                    ItemsTab(vm, r, items, busy, highlightItemId, onDeleteReceipt = { confirmDelete = true })
                }
            }
            val snack = snacks.current
            if (snack != null) SnackbarBar(snack, snacks::performUndo, Modifier.padding(start = 14.dp, end = 14.dp, bottom = 8.dp))
            ReviewBar(
                r, list, busy, onBack, onNext, vm,
                onRerun = { confirmRerun = true }, onDelete = { confirmDelete = true },
            )
        }
    }

    if (confirmDelete) AppConfirmDialog(
        title = "Delete this receipt?",
        message = "It moves to \"Recently deleted\" and can be restored from there.",
        confirmLabel = "Delete", destructive = true,
        onConfirm = {
            confirmDelete = false
            // The receipt leaves the screen; the bar with Undo is shown by wherever we land.
            vm.deleteReceipt { snacks.show("Moved to Recently deleted") { vm.restoreReceipt() } }
        },
        onDismiss = { confirmDelete = false },
    )
    if (confirmRerun) AppConfirmDialog(
        title = "Re-run extraction?",
        message = "The server reads the photo again and marks the receipt as not yet reviewed. If you already edited or confirmed this receipt, the server keeps your version.",
        confirmLabel = "Re-run extraction", destructive = true,
        onConfirm = { confirmRerun = false; vm.retryExtraction { errors.show(it) } },
        onDismiss = { confirmRerun = false },
    )
}

/** The bar under the tabs: the "n more to review" hint, `Looks good` (or the `Reviewed ✓` status) and the overflow menu. */
@Composable
private fun ReviewBar(
    r: ReceiptEntity,
    list: ListUi,
    busy: Boolean,
    onBack: () -> Unit,
    onNext: (String) -> Unit,
    vm: DetailViewModel,
    onRerun: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = AppTheme.colors
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    var menu by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }
    val processing = r.processing
    val enabled = DetailLogic.looksGoodEnabled(busy, processing?.isActive == true) && !confirming

    fun looksGood() {
        if (!enabled) return
        confirming = true
        scope.launch {
            focus.clearFocus()
            vm.confirm().join()
            // The next one to review is looked for in ALL receipts, not in what the list currently filters to.
            val next = ReviewQueue.next(r.uuid, list.all)
            if (next != null) onNext(next.uuid) else onBack()
            confirming = false
        }
    }

    Column(Modifier.fillMaxWidth().background(colors.paper)) {
        RuleDivider()
        Column(Modifier.padding(start = 14.dp, end = 14.dp, top = 8.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (r.reviewedAt == null && processing == null) {
                Text(
                    ReviewQueue.hint(r.uuid, list.all), Modifier.fillMaxWidth().testTag("nextToReviewHint"),
                    style = AppTheme.body(12.5f, color = colors.inkSoft), textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                val shape = RoundedCornerShape(10.dp)
                if (r.reviewedAt != null) {
                    // A status rather than a dimmed button.
                    Box(
                        Modifier.weight(1f).heightIn(min = 48.dp).clip(shape).background(colors.greenBg),
                        contentAlignment = Alignment.Center,
                    ) { Text("Reviewed ✓", style = AppTheme.body(16, FontWeight.SemiBold, colors.greenText)) }
                } else {
                    Row(
                        Modifier.weight(1f).heightIn(min = 48.dp).testTag("looksGoodButton")
                            .alpha(if (enabled) 1f else 0.45f).clip(shape).background(colors.green)
                            .clickable(enabled = enabled, role = Role.Button, onClick = ::looksGood)
                            .semantics(mergeDescendants = true) { contentDescription = "Looks good" },
                        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.Check, null, Modifier.size(18.dp), tint = colors.onGreen)
                        Text("Looks good", style = AppTheme.body(16, FontWeight.SemiBold, colors.onGreen))
                    }
                }
                Box {
                    AppIconButton(
                        Icons.Filled.MoreVert, "More", { menu = true },
                        Modifier.size(48.dp).testTag("moreMenu"), tint = colors.ink, iconSize = 24.dp, enabled = !busy,
                    )
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, containerColor = colors.paper) {
                        // The phone has no AI of its own: the server re-reads a photo it still holds.
                        if (r.photoLocation == "server") {
                            DropdownMenuItem(
                                text = { Text("Re-run extraction…", style = AppTheme.body(14, color = colors.ink)) },
                                onClick = { menu = false; onRerun() },
                            )
                        }
                        DropdownMenuItem(
                            text = { Text("Delete receipt…", style = AppTheme.body(14, color = colors.red)) },
                            onClick = { menu = false; onDelete() },
                        )
                    }
                }
            }
        }
    }
}
