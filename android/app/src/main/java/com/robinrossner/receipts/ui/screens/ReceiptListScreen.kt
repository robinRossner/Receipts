package com.robinrossner.receipts.ui.screens

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DocumentScanner
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.ImportJob
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.data.sync.SyncPhase
import com.robinrossner.receipts.ui.DateRange
import com.robinrossner.receipts.ui.ListViewModel
import com.robinrossner.receipts.ui.components.Paper
import com.robinrossner.receipts.ui.components.SectionLabel
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.processing
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReceiptListScreen(container: AppContainer, vm: ListViewModel, onOpen: (String) -> Unit, goToSettings: () -> Unit) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val sync by container.coordinator.state.collectAsStateWithLifecycle()
    val jobs by container.importer.jobs.collectAsStateWithLifecycle()
    val search by vm.searchText.collectAsStateWithLifecycle()
    val range by vm.dateRange.collectAsStateWithLifecycle()
    val storeFilter by vm.storeFilter.collectAsStateWithLifecycle()
    val colors = AppTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var refreshing by remember { mutableStateOf(false) }
    var filterMenu by remember { mutableStateOf(false) }
    var confirmAll by remember { mutableStateOf(false) }
    var pendingPurge by remember { mutableStateOf<ReceiptSummary?>(null) }
    var showDeleted by remember { mutableStateOf(false) }
    val configured = container.coordinator.isConfigured

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris ->
        if (uris.isNotEmpty()) container.importer.import(uris)
    }
    val scanner = remember {
        GmsDocumentScanning.getClient(
            GmsDocumentScannerOptions.Builder()
                .setGalleryImportAllowed(false)
                .setPageLimit(5)
                .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
                .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
                .build(),
        )
    }
    val scanLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (result.resultCode != Activity.RESULT_OK) return@rememberLauncherForActivityResult
        val pages = GmsDocumentScanningResult.fromActivityResultIntent(result.data)?.pages.orEmpty()
        val first = pages.firstOrNull() ?: return@rememberLauncherForActivityResult
        container.importer.import(listOf(first.imageUri))
        // A receipt is one photo (one sha256, one image), so a multi-page scan is not merged: the first page is the receipt.
        if (pages.size > 1) scope.launch {
            snackbar.showSnackbar("Only the first of ${pages.size} pages was added. A receipt is one photo; scan the other pages as separate receipts.")
        }
    }
    fun startScan() {
        val activity = context.findActivity() ?: return
        scanner.getStartScanIntent(activity)
            .addOnSuccessListener { scanLauncher.launch(IntentSenderRequest.Builder(it).build()) }
            .addOnFailureListener {
                scope.launch { snackbar.showSnackbar("The document scanner is not available on this device (${it.message ?: "Google Play services"}). Use “Choose photos” instead.") }
            }
    }

    Scaffold(
        containerColor = colors.desk,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Receipts", style = AppTheme.display(20.sp), color = colors.ink) },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = colors.paper, titleContentColor = colors.ink),
                navigationIcon = {
                    Box {
                        IconButton(onClick = { filterMenu = true }, modifier = Modifier.testTag("filtersMenu")) {
                            Icon(Icons.Default.FilterList, contentDescription = "Filters", tint = if (ui.isFiltering) colors.penRed else colors.ink)
                        }
                        DropdownMenu(expanded = filterMenu, onDismissRequest = { filterMenu = false }) {
                            Text("Date", Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = AppTheme.body(11, color = colors.inkSoft))
                            DateRange.entries.forEach { r ->
                                DropdownMenuItem(
                                    text = { Text((if (r == range) "✓ " else "    ") + r.label) },
                                    onClick = { vm.dateRange.value = r; filterMenu = false },
                                )
                            }
                            Text("Store", Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = AppTheme.body(11, color = colors.inkSoft))
                            DropdownMenuItem(text = { Text((if (storeFilter == null) "✓ " else "    ") + "All stores") }, onClick = { vm.storeFilter.value = null; filterMenu = false })
                            ui.storesInUse.forEach { s ->
                                DropdownMenuItem(text = { Text((if (storeFilter == s) "✓ " else "    ") + s) }, onClick = { vm.storeFilter.value = s; filterMenu = false })
                            }
                            if (ui.isFiltering) DropdownMenuItem(text = { Text("Clear filters") }, onClick = { vm.clearFilters(); filterMenu = false })
                            if (ui.confirmableWithoutFlags.isNotEmpty()) {
                                DropdownMenuItem(
                                    text = { Text("Confirm all without flags (${ui.confirmableWithoutFlags.size})") },
                                    onClick = { confirmAll = true; filterMenu = false },
                                )
                            }
                        }
                    }
                },
                actions = {
                    IconButton(onClick = ::startScan, modifier = Modifier.testTag("scanButton")) {
                        Icon(Icons.Default.DocumentScanner, contentDescription = "Scan receipt", tint = colors.ink)
                    }
                    IconButton(
                        onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                        modifier = Modifier.testTag("photosButton"),
                    ) { Icon(Icons.Default.PhotoLibrary, contentDescription = "Choose photos", tint = colors.ink) }
                },
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            if (!configured && ui.all.isEmpty()) {
                SetupPrompt(goToSettings)
            } else {
                PullToRefreshBox(
                    isRefreshing = refreshing,
                    onRefresh = { scope.launch { refreshing = true; vm.refresh().join(); refreshing = false } },
                ) {
                    LazyColumn(
                        Modifier.fillMaxSize().testTag("receiptList"),
                        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        item("search") {
                            OutlinedTextField(
                                value = search, onValueChange = { vm.searchText.value = it }, singleLine = true,
                                modifier = Modifier.fillMaxWidth().testTag("searchField"),
                                placeholder = { Text("Store, item or amount", style = AppTheme.body(14, color = colors.inkSoft)) },
                                leadingIcon = { Icon(Icons.Default.Search, null, tint = colors.inkSoft) },
                                trailingIcon = {
                                    if (search.isNotEmpty()) IconButton(onClick = { vm.searchText.value = "" }) { Icon(Icons.Default.Close, "Clear search", tint = colors.inkSoft) }
                                },
                                shape = RoundedCornerShape(4.dp),
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedContainerColor = colors.paper, unfocusedContainerColor = colors.paper,
                                    focusedBorderColor = colors.ink, unfocusedBorderColor = colors.rule,
                                ),
                            )
                        }
                        if (sync.phase != SyncPhase.OFF) item("status") { SyncStatusRow(container) }
                        if (jobs.isNotEmpty()) item("uploads") { UploadQueue(container, jobs, onOpen) }
                        if (ui.all.isEmpty()) item("empty") { EmptyNote("No receipts yet. Scan one with the camera or choose photos.") }
                        else if (ui.filtered.isEmpty()) item("nomatch") { EmptyNote("No receipts match.") }
                        section("Needs review", ui.unreviewed, ui.unreviewed.size, onOpen) { vm.delete(it) }
                        section("Reviewed", ui.reviewed, null, onOpen) { vm.delete(it) }
                        if (ui.deleted.isNotEmpty()) {
                            item("deleted") {
                                Column {
                                    Row(
                                        Modifier.fillMaxWidth().clickable { showDeleted = !showDeleted }.padding(vertical = 8.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        SectionLabel("Recently deleted (${ui.deleted.size})")
                                        Text(if (showDeleted) "  ▾" else "  ▸", style = AppTheme.body(11, color = colors.inkSoft))
                                    }
                                    if (showDeleted) ui.deleted.forEach { r ->
                                        Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                            Column(Modifier.weight(1f)) {
                                                Text(r.store ?: "Unknown", style = AppTheme.body(13, FontWeight.SemiBold, colors.ink))
                                                Text("${r.date ?: ""} · ${fmtMoney(r.total)}", style = AppTheme.mono(11, color = colors.inkSoft))
                                            }
                                            TextButton(onClick = { vm.restore(r.uuid) }) { Text("Restore", color = colors.ink) }
                                            TextButton(onClick = { pendingPurge = r }) { Text("Delete", color = colors.penRed) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (confirmAll) AlertDialog(
        onDismissRequest = { confirmAll = false },
        title = { Text("Confirm ${ui.confirmableWithoutFlags.size} receipts without flags?") },
        text = { Text("Marks every unreviewed receipt that has no review reasons as reviewed. Receipts with warnings stay in “Needs review”.") },
        confirmButton = { TextButton(onClick = { vm.confirmAllWithoutFlags(); confirmAll = false }) { Text("Confirm all") } },
        dismissButton = { TextButton(onClick = { confirmAll = false }) { Text("Cancel") } },
    )
    pendingPurge?.let { r ->
        AlertDialog(
            onDismissRequest = { pendingPurge = null },
            title = { Text("Permanently delete this receipt?") },
            text = { Text("This removes the receipt, its items and the photo copy on this phone. It cannot be undone.") },
            confirmButton = { TextButton(onClick = { vm.purge(r.uuid); pendingPurge = null }) { Text("Delete permanently", color = colors.penRed) } },
            dismissButton = { TextButton(onClick = { pendingPurge = null }) { Text("Cancel") } },
        )
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.section(
    title: String, rows: List<ReceiptSummary>, badge: Int?, onOpen: (String) -> Unit, onDelete: (String) -> Unit,
) {
    if (rows.isEmpty()) return
    item("h-$title") {
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            SectionLabel(title)
            Spacer(Modifier.weight(1f))
            if (badge != null && badge > 0) {
                Text(
                    "$badge to review",
                    Modifier.background(AppTheme.colors.penRed, CircleShape).padding(horizontal = 8.dp, vertical = 2.dp),
                    style = AppTheme.body(11, FontWeight.Medium, Color.White),
                )
            }
        }
    }
    items(rows, key = { it.uuid }) { r -> SwipeableRow(r, onOpen, onDelete) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeableRow(r: ReceiptSummary, onOpen: (String) -> Unit, onDelete: (String) -> Unit) {
    val state = rememberSwipeToDismissBoxState(confirmValueChange = {
        if (it == SwipeToDismissBoxValue.EndToStart) { onDelete(r.uuid); true } else false
    })
    SwipeToDismissBox(
        state = state, enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(Modifier.fillMaxSize().clip(RoundedCornerShape(4.dp)).background(AppTheme.colors.penRed).padding(end = 16.dp), contentAlignment = Alignment.CenterEnd) {
                Text("Delete", style = AppTheme.body(13, FontWeight.Medium, Color.White))
            }
        },
    ) { ReceiptRow(r) { onOpen(r.uuid) } }
}

@Composable
private fun ReceiptRow(r: ReceiptSummary, onClick: () -> Unit) {
    val colors = AppTheme.colors
    val unreviewed = r.reviewedAt == null
    val processing = r.processing
    Paper(Modifier.fillMaxWidth().clickable(onClick = onClick).testTag("receiptRow")) {
        Box {
            Row(Modifier.fillMaxWidth().padding(start = if (unreviewed) 15.dp else 12.dp, end = 12.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(r.store ?: if (processing == null) "Unknown" else "New receipt", style = AppTheme.body(15, FontWeight.SemiBold, colors.ink))
                    if (processing != null) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            if (processing.isActive) CircularProgressIndicator(Modifier.size(11.dp), strokeWidth = 1.5.dp, color = colors.inkSoft)
                            Text(processing.label, style = AppTheme.body(12, color = if (processing.isActive) colors.inkSoft else colors.penRed))
                        }
                    } else {
                        Text(r.date ?: "", style = AppTheme.mono(12, color = colors.inkSoft))
                    }
                }
                if (processing == null || r.total != null) Text(fmtMoney(r.total), style = AppTheme.mono(14, color = colors.ink))
            }
            if (unreviewed) Box(Modifier.width(3.dp).fillMaxHeight().background(colors.penRed).align(Alignment.CenterStart))
            if (r.needsReview) Text("⚠", Modifier.align(Alignment.TopEnd).padding(5.dp), style = AppTheme.body(11, color = colors.penRed))
        }
    }
}

@Composable
private fun EmptyNote(text: String) {
    Text(text, Modifier.fillMaxWidth().padding(vertical = 24.dp), style = AppTheme.body(14, color = AppTheme.colors.inkSoft), textAlign = TextAlign.Center)
}

@Composable
private fun SetupPrompt(goToSettings: () -> Unit) {
    val colors = AppTheme.colors
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Connect to your server", style = AppTheme.display(20.sp, colors.ink))
        Text(
            "Receipts are read by your own backend. Enter its address and the receipts token in Settings.",
            style = AppTheme.body(14, color = colors.inkSoft), textAlign = TextAlign.Center,
        )
        com.robinrossner.receipts.ui.components.InkButton("Open Settings", Modifier.testTag("openSettingsButton"), onClick = goToSettings)
    }
}

@Composable
private fun SyncStatusRow(container: AppContainer) {
    val sync by container.coordinator.state.collectAsStateWithLifecycle()
    val colors = AppTheme.colors
    val text = when (sync.phase) {
        SyncPhase.OFF -> ""
        SyncPhase.SYNCING -> "Syncing…"
        SyncPhase.IDLE -> when {
            sync.lastError != null -> if (sync.nextRetryAtMillis != null) "Sync failed, retrying" else "Sync failed"
            sync.lastSyncAt != null -> "Synced " + DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(sync.lastSyncAt!!.toEpochMilli()))
            else -> "Not synced yet"
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (sync.phase == SyncPhase.SYNCING) CircularProgressIndicator(Modifier.size(11.dp), strokeWidth = 1.5.dp, color = colors.inkSoft)
        Text(text, Modifier.testTag("syncStatus"), style = AppTheme.body(11, color = if (sync.lastError != null) colors.penRed else colors.inkSoft))
        Icon(
            Icons.Default.Sync, "Sync now",
            Modifier.size(14.dp).clickable(enabled = sync.phase != SyncPhase.SYNCING) { container.scope.launch { container.coordinator.syncNow() } },
            tint = colors.inkSoft,
        )
    }
}

@Composable
private fun UploadQueue(container: AppContainer, jobs: List<ImportJob>, onOpen: (String) -> Unit) {
    val colors = AppTheme.colors
    val finished = jobs.count { it.finished }
    Column(Modifier.fillMaxWidth().testTag("uploadQueue"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionLabel("Photos - $finished of ${jobs.size}")
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { container.importer.clearFinished() }) { Text("Clear finished", style = AppTheme.body(11, color = colors.inkSoft)) }
        }
        LinearProgressIndicator(progress = { finished.toFloat() / jobs.size.coerceAtLeast(1) }, Modifier.fillMaxWidth(), color = colors.penRed, trackColor = colors.rule)
        jobs.forEach { job ->
            val (text, failed) = when (val s = job.state) {
                ImportJob.State.Queued -> "Waiting" to false
                ImportJob.State.Preparing -> "Preparing…" to false
                is ImportJob.State.Saved -> "Saved; uploads when the server is reachable" to false
                is ImportJob.State.Duplicate -> "Already imported" to false
                is ImportJob.State.Failed -> s.message to true
            }
            val target = (job.state as? ImportJob.State.Saved)?.receiptUuid ?: (job.state as? ImportJob.State.Duplicate)?.receiptUuid
            Row(
                Modifier.fillMaxWidth().clickable(enabled = target != null) { target?.let(onOpen) },
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top,
            ) {
                if (!job.finished) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 1.5.dp, color = colors.inkSoft)
                else Text(if (failed) "⚠" else "✓", style = AppTheme.body(12, color = if (failed) colors.penRed else colors.ink))
                Column(Modifier.weight(1f)) {
                    Text(job.name, maxLines = 1, style = AppTheme.body(12, color = colors.ink))
                    Text(text, style = AppTheme.body(11, color = if (failed) colors.penRed else colors.inkSoft))
                }
            }
        }
    }
}
