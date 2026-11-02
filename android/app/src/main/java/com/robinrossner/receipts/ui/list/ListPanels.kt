package com.robinrossner.receipts.ui.list

import android.text.format.DateUtils
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.DocumentScanner
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.RemoveCircleOutline
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.FocusManager
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.data.ImportJob
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.data.sync.SyncPhase
import com.robinrossner.receipts.data.sync.SyncUiState
import com.robinrossner.receipts.ui.DateRange
import com.robinrossner.receipts.ui.ListUi
import com.robinrossner.receipts.ui.components.AppChip
import com.robinrossner.receipts.ui.components.AppFlowRow
import com.robinrossner.receipts.ui.components.AppIconButton
import com.robinrossner.receipts.ui.components.AppTextField
import com.robinrossner.receipts.ui.components.MiniSpinner
import com.robinrossner.receipts.ui.components.OutlineButton
import com.robinrossner.receipts.ui.components.RuleDivider
import com.robinrossner.receipts.ui.components.SectionLabel
import com.robinrossner.receipts.ui.components.Thumbnail
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.components.paperCard
import com.robinrossner.receipts.ui.theme.AppTheme
import com.robinrossner.receipts.ui.theme.EaseOut
import kotlinx.coroutines.delay

// ---- Search band -------------------------------------------------------------------------------------------------

/** The pinned search field under the top bar: `paper` band, `desk` field, one rule below (reads as one header with the bar). */
@Composable
fun SearchBand(text: String, onChange: (String) -> Unit, focus: FocusManager) {
    val colors = AppTheme.colors
    Column(Modifier.fillMaxWidth().background(colors.paper)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp).height(40.dp)
                .clip(RoundedCornerShape(10.dp)).background(colors.desk).padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.Outlined.Search, null, Modifier.size(18.dp), tint = colors.inkSoft)
            AppTextField(
                value = text, onValueChange = onChange, boxed = false,
                modifier = Modifier.weight(1f).testTag("searchField"),
                textStyle = AppTheme.body(16, color = colors.ink),
                placeholder = "Store, item or amount",
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }),
            )
            if (text.isNotEmpty()) {
                Icon(
                    Icons.Filled.Cancel, "Clear search",
                    Modifier.size(18.dp).clickable(role = Role.Button) { onChange("") },
                    tint = colors.inkSoft,
                )
            }
        }
        RuleDivider()
    }
}

// ---- Setup / empty / no match ----------------------------------------------------------------------------------

@Composable
fun SetupPrompt(goToSettings: () -> Unit) {
    val colors = AppTheme.colors
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Outlined.CloudUpload, null, Modifier.size(44.dp), tint = colors.label)
        Text("Connect to your server", style = AppTheme.display(22, colors.ink), textAlign = TextAlign.Center)
        Text(
            "Receipts are read by your own backend. Enter its address and the receipts token in Settings.",
            style = AppTheme.body(15, color = colors.label), textAlign = TextAlign.Center,
        )
        OutlineButton("Open Settings", goToSettings, Modifier.padding(top = 4.dp), fill = true, testTag = "openSettingsButton")
    }
}

@Composable
fun EmptyState(onScan: () -> Unit, onPhotos: () -> Unit) {
    val colors = AppTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 40.dp, bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Outlined.DocumentScanner, null, Modifier.size(44.dp), tint = colors.label)
        Text("No receipts yet. Scan one with the camera or choose photos.", style = AppTheme.body(15, color = colors.label), textAlign = TextAlign.Center)
        Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlineButton("Scan receipt", onScan, fill = true, icon = Icons.Outlined.DocumentScanner)
            OutlineButton("Choose photos", onPhotos, icon = Icons.Outlined.PhotoLibrary)
        }
    }
}

@Composable
fun NoMatchState(onClear: () -> Unit) {
    val colors = AppTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(top = 40.dp, bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Outlined.Search, null, Modifier.size(36.dp), tint = colors.label)
        Text("No receipts match.", style = AppTheme.body(15, color = colors.label), textAlign = TextAlign.Center)
        OutlineButton("Clear filters", onClear)
    }
}

// ---- Section header ---------------------------------------------------------------------------------------------

/** Sticky section header: `desk` background so rows slide under it, optional red "n to review" capsule. */
@Composable
fun SectionHeader(title: String, toReview: Int? = null) {
    val colors = AppTheme.colors
    Row(
        Modifier.fillMaxWidth().background(colors.desk).padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SectionLabel(title)
        Spacer(Modifier.weight(1f))
        if (toReview != null && toReview > 0) {
            Text(
                ListLogic.toReviewBadge(toReview),
                Modifier.background(colors.red, CircleShape).padding(horizontal = 9.dp, vertical = 3.dp),
                style = AppTheme.body(12, FontWeight.SemiBold, colors.onRed),
            )
        }
    }
}

// ---- Sync row ----------------------------------------------------------------------------------------------------

@Composable
fun SyncStatusRow(sync: SyncUiState, onSyncNow: () -> Unit) {
    val colors = AppTheme.colors
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) { delay(30_000); now = System.currentTimeMillis() }
    }
    // Recomputed when the state or the clock changes.
    val model = SyncRow.make(sync, maxOf(now, System.currentTimeMillis())) { then, current ->
        DateUtils.getRelativeTimeSpanString(then, current, DateUtils.MINUTE_IN_MILLIS).toString()
    } ?: return
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (model.dot == SyncDot.SPINNER) {
            MiniSpinner()
        } else {
            val dot = when (model.dot) {
                SyncDot.RED -> colors.red
                SyncDot.AMBER -> colors.series[1]
                SyncDot.NEVER -> colors.seriesOther
                else -> colors.green
            }
            Box(Modifier.size(7.dp).background(dot, CircleShape))
        }
        Text(
            model.text, Modifier.weight(1f).testTag("syncStatus"),
            style = AppTheme.body(12.5f, color = if (model.hardFailure) colors.red else colors.label),
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        AppIconButton(
            Icons.Outlined.Sync, "Sync now", onSyncNow, Modifier.offset(x = 10.dp).testTag("syncNow"),
            tint = colors.label, iconSize = 14.dp, enabled = sync.phase != SyncPhase.SYNCING,
        )
    }
}

// ---- Active filter tags ------------------------------------------------------------------------------------------

@Composable
fun ActiveFilterTags(filters: List<ActiveFilter>, onRemove: (ActiveFilter.Kind) -> Unit) {
    AppFlowRow(6.dp, modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 2.dp, bottom = 6.dp)) {
        filters.forEach { f -> com.robinrossner.receipts.ui.components.FilterTag(f.text, onRemove = { onRemove(f.kind) }) }
    }
}

// ---- Upload panel ------------------------------------------------------------------------------------------------

@Composable
fun UploadQueuePanel(
    jobs: List<ImportJob>,
    onOpen: (String) -> Unit,
    onCancel: (String) -> Unit,
    onCancelAll: () -> Unit,
    onRetryFailed: () -> Unit,
    onClearFinished: () -> Unit,
) {
    val colors = AppTheme.colors
    Column(Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 4.dp, bottom = 8.dp)) {
        Column(Modifier.fillMaxWidth().testTag("uploadQueue").paperCard(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionLabel(UploadPanel.title(jobs))
            LinearProgressIndicator(
                progress = { UploadPanel.progress(jobs) },
                modifier = Modifier.fillMaxWidth().height(4.dp).clip(CircleShape),
                color = colors.ink, trackColor = colors.rule, gapSize = 0.dp, drawStopIndicator = {},
            )
            Column(Modifier.fillMaxWidth().heightIn(max = 232.dp).verticalScroll(rememberScrollState())) {
                jobs.forEach { job -> UploadJobRow(job, onOpen, onCancel) }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (UploadPanel.canCancelAll(jobs)) PanelButton("Cancel all", onCancelAll)
                if (UploadPanel.canRetry(jobs)) PanelButton("Retry failed", onRetryFailed)
                PanelButton("Clear finished", onClearFinished)
            }
        }
    }
}

@Composable
private fun UploadJobRow(job: ImportJob, onOpen: (String) -> Unit, onCancel: (String) -> Unit) {
    val colors = AppTheme.colors
    val target = UploadPanel.receiptOf(job.state)
    Row(
        Modifier.fillMaxWidth().clickable(enabled = target != null) { target?.let(onOpen) }.padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Thumbnail(job.thumbnail, Modifier.size(22.dp))
        Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
            when (job.state) {
                ImportJob.State.Queued -> Icon(Icons.Outlined.Schedule, null, Modifier.size(13.dp), tint = colors.inkSoft)
                ImportJob.State.Preparing -> MiniSpinner(14.dp)
                is ImportJob.State.Saved -> Icon(Icons.Filled.CheckCircle, null, Modifier.size(14.dp), tint = colors.greenText)
                is ImportJob.State.Duplicate -> Icon(Icons.Outlined.ContentCopy, null, Modifier.size(12.dp), tint = colors.inkSoft)
                is ImportJob.State.Failed -> Icon(Icons.Filled.Error, null, Modifier.size(14.dp), tint = colors.red)
                ImportJob.State.Cancelled -> Icon(Icons.Outlined.RemoveCircleOutline, null, Modifier.size(14.dp), tint = colors.inkSoft)
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(job.name, style = AppTheme.body(13, FontWeight.Medium, colors.ink), maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            Text(
                UploadPanel.status(job.state),
                style = AppTheme.body(12, color = if (job.state is ImportJob.State.Failed) colors.red else colors.inkSoft),
            )
        }
        if (!job.finished) {
            // 6dp negative vertical padding: the 44dp tap target must not make the row taller.
            AppIconButton(
                Icons.Filled.Close, "Cancel upload", { onCancel(job.id) },
                Modifier.layout { measurable, constraints ->
                    val p = measurable.measure(constraints)
                    val trim = 6.dp.roundToPx()
                    layout(p.width, (p.height - 2 * trim).coerceAtLeast(0)) { p.place(0, -trim) }
                },
                iconSize = 12.dp,
            )
        }
    }
}

@Composable
private fun RowScope.PanelButton(text: String, onClick: () -> Unit) {
    val colors = AppTheme.colors
    val shape = RoundedCornerShape(7.dp)
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    Box(
        Modifier.weight(1f).heightIn(min = 38.dp).alpha(if (pressed) 0.6f else 1f)
            .border(1.dp, colors.rule, shape).clip(shape)
            .clickable(interactionSource = source, indication = null, role = Role.Button, onClick = onClick)
            .padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, style = AppTheme.body(13, FontWeight.Medium, colors.ink), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

// ---- Recently deleted --------------------------------------------------------------------------------------------

@Composable
fun RecentlyDeletedHeader(count: Int, open: Boolean, onToggle: () -> Unit) {
    val colors = AppTheme.colors
    val angle by animateFloatAsState(if (open) 90f else 0f, tween(200, easing = EaseOut), label = "chevron")
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 10.dp).heightIn(min = 44.dp)
            .clickable(role = Role.Button, onClick = onToggle),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SectionLabel("Recently deleted ($count)")
        Spacer(Modifier.weight(1f))
        Icon(Icons.Filled.KeyboardArrowRight, null, Modifier.size(12.dp).rotate(angle), tint = colors.label)
    }
}

@Composable
fun DeletedRow(r: ReceiptSummary, onRestore: () -> Unit, onDelete: () -> Unit) {
    val colors = AppTheme.colors
    val shape = RoundedCornerShape(AppTheme.corner)
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 3.dp)
            .background(colors.paper.copy(alpha = 0.6f), shape).border(1.dp, colors.rule, shape)
            .padding(start = 12.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(r.store ?: "Unknown", style = AppTheme.body(15, FontWeight.SemiBold, colors.ink), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(ListLogic.deletedLine(r, fmtMoney(r.total)), style = AppTheme.mono(12, color = colors.inkSoft), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        OutlineButton("Restore", onRestore)
        OutlineButton("Delete", onDelete, color = colors.red)
    }
}

// ---- Filter sheet ------------------------------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FilterSheet(
    sheetState: SheetState,
    ui: ListUi,
    range: DateRange,
    storeFilter: String?,
    onRange: (DateRange) -> Unit,
    onStore: (String?) -> Unit,
    onClear: () -> Unit,
    onConfirmAll: () -> Unit,
    onDone: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = AppTheme.colors
    val minHeight = (LocalConfiguration.current.screenHeightDp * 0.72f).dp
    val confirmable = ui.confirmableWithoutFlags.size
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = colors.desk) {
        Column(Modifier.fillMaxWidth().heightIn(min = minHeight)) {
            Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), contentAlignment = Alignment.Center) {
                Text("Filters", style = AppTheme.display(18, colors.ink))
                TextButton(onClick = onDone, modifier = Modifier.align(Alignment.CenterEnd).testTag("filtersDone")) {
                    Text("Done", style = AppTheme.body(16, FontWeight.SemiBold, colors.ink))
                }
            }
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionLabel("Date")
                    AppFlowRow(6.dp) {
                        DateRange.entries.forEach { r -> AppChip(r.label, selected = r == range, onClick = { onRange(r) }) }
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionLabel("Store")
                    AppFlowRow(6.dp) {
                        AppChip("All stores", selected = storeFilter == null, onClick = { onStore(null) })
                        ui.storesInUse.forEach { s -> AppChip(s, selected = s == storeFilter, onClick = { onStore(if (s == storeFilter) null else s) }) }
                    }
                }
                Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(ListLogic.resultCount(ui.filtered.size), Modifier.testTag("filterResultCount"), style = AppTheme.mono(13, color = colors.label))
                    Spacer(Modifier.weight(1f))
                    if (ui.isFiltering) OutlineButton("Clear filters", onClear)
                }
                if (confirmable > 0) {
                    RuleDivider()
                    OutlineButton(
                        ListLogic.confirmAllButton(confirmable), onConfirmAll, Modifier.fillMaxWidth(),
                        color = colors.greenText, icon = Icons.Outlined.Verified,
                    )
                }
            }
        }
    }
}
