package com.robinrossner.receipts.ui.screens

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FilterAlt
import androidx.compose.material.icons.outlined.DocumentScanner
import androidx.compose.material.icons.outlined.FilterAlt
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.data.sync.SyncPhase
import com.robinrossner.receipts.ui.DateRange
import com.robinrossner.receipts.ui.ListViewModel
import com.robinrossner.receipts.ui.components.AppAlertDialog
import com.robinrossner.receipts.ui.components.AppConfirmDialog
import com.robinrossner.receipts.ui.components.AppIconButton
import com.robinrossner.receipts.ui.components.AppTopBar
import com.robinrossner.receipts.ui.components.LocalSnackCenter
import com.robinrossner.receipts.ui.list.ActiveFilter
import com.robinrossner.receipts.ui.list.ActiveFilterTags
import com.robinrossner.receipts.ui.list.DeletedRow
import com.robinrossner.receipts.ui.list.EmptyState
import com.robinrossner.receipts.ui.list.FilterSheet
import com.robinrossner.receipts.ui.list.ListLogic
import com.robinrossner.receipts.ui.list.NoMatchState
import com.robinrossner.receipts.ui.list.RecentlyDeletedHeader
import com.robinrossner.receipts.ui.list.SearchBand
import com.robinrossner.receipts.ui.list.SectionHeader
import com.robinrossner.receipts.ui.list.SetupPrompt
import com.robinrossner.receipts.ui.list.SwipeableReceiptRow
import com.robinrossner.receipts.ui.list.SyncStatusRow
import com.robinrossner.receipts.ui.list.UploadQueuePanel
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.launch

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

/** The most photos one pick may return: 20, or less where the system picker allows fewer. */
private fun pickerLimit(): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) minOf(20, runCatching { MediaStore.getPickImagesMaxLimit() }.getOrDefault(20)).coerceAtLeast(2) else 20

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ReceiptListScreen(container: AppContainer, vm: ListViewModel, onOpen: (String) -> Unit, goToSettings: () -> Unit) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val sync by container.coordinator.state.collectAsStateWithLifecycle()
    val jobs by container.importer.jobs.collectAsStateWithLifecycle()
    val search by vm.searchText.collectAsStateWithLifecycle()
    val range by vm.dateRange.collectAsStateWithLifecycle()
    val storeFilter by vm.storeFilter.collectAsStateWithLifecycle()
    val reasons by vm.reviewReasons.collectAsStateWithLifecycle()
    val colors = AppTheme.colors
    val context = LocalContext.current
    val focus = LocalFocusManager.current
    val snacks = LocalSnackCenter.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val pullState = rememberPullToRefreshState()
    var refreshing by remember { mutableStateOf(false) }
    var showFilters by remember { mutableStateOf(false) }
    var confirmAll by remember { mutableStateOf(false) }
    var pendingPurge by remember { mutableStateOf<ReceiptSummary?>(null) }
    var showDeleted by remember { mutableStateOf(false) }
    var captureNote by remember { mutableStateOf<String?>(null) }
    var scannerUnavailable by remember { mutableStateOf(false) }
    val configured = container.coordinator.isConfigured
    val setup = !configured && ui.all.isEmpty()

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(pickerLimit())) { uris ->
        if (uris.isNotEmpty()) container.importer.import(uris) { failed ->
            if (failed > 0) captureNote = ListLogic.photosNotLoaded(failed)
        }
    }
    fun choosePhotos() = picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))

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
        if (pages.size > 1) captureNote = ListLogic.onlyFirstPage(pages.size)
    }
    fun startScan() {
        val activity = context.findActivity() ?: return
        scanner.getStartScanIntent(activity)
            .addOnSuccessListener { scanLauncher.launch(IntentSenderRequest.Builder(it).build()) }
            .addOnFailureListener {
                Log.w("ReceiptList", "Document scanner unavailable", it)
                scannerUnavailable = true
            }
    }

    fun confirm(r: ReceiptSummary) {
        scope.launch { if (vm.confirm(r.uuid)) snacks.show(ListLogic.reviewedSnack(r)) { vm.unconfirm(r.uuid) } }
    }
    fun delete(r: ReceiptSummary) {
        scope.launch {
            vm.delete(r.uuid)
            snacks.show(ListLogic.DELETED_SNACK) { vm.restore(r.uuid) }
        }
    }

    val unreviewed = remember(ui.filtered) { ui.unreviewed }
    val reviewed = remember(ui.filtered) { ui.reviewed }
    val filters = ListLogic.activeFilters(search, range, storeFilter)

    Column(Modifier.fillMaxSize().background(colors.desk)) {
        AppTopBar(
            "Receipts", titleSize = 20f,
            navigationIcon = {
                AppIconButton(
                    if (ui.isFiltering) Icons.Filled.FilterAlt else Icons.Outlined.FilterAlt, "Filters", { showFilters = true },
                    Modifier.testTag("filtersMenu"), tint = colors.ink, iconSize = 24.dp,
                )
            },
            actions = {
                AppIconButton(Icons.Outlined.DocumentScanner, "Scan receipt", ::startScan, Modifier.testTag("scanButton"), tint = colors.ink, iconSize = 24.dp)
                AppIconButton(Icons.Outlined.PhotoLibrary, "Choose photos", ::choosePhotos, Modifier.testTag("photosButton"), tint = colors.ink, iconSize = 24.dp)
            },
        )
        if (!setup) SearchBand(search, { vm.searchText.value = it }, focus)
        Box(Modifier.weight(1f).fillMaxSize()) {
            if (setup) {
                SetupPrompt(goToSettings)
            } else {
                PullToRefreshBox(
                    isRefreshing = refreshing,
                    onRefresh = { scope.launch { refreshing = true; vm.refresh().join(); refreshing = false } },
                    state = pullState,
                    indicator = {
                        PullToRefreshDefaults.Indicator(
                            state = pullState, isRefreshing = refreshing, modifier = Modifier.align(Alignment.TopCenter),
                            containerColor = colors.paper, color = colors.ink,
                        )
                    },
                ) {
                    LazyColumn(Modifier.fillMaxSize().testTag("receiptList"), contentPadding = PaddingValues(bottom = 16.dp)) {
                        if (sync.phase != SyncPhase.OFF) item("sync") { SyncStatusRow(sync) { scope.launch { container.coordinator.syncNow() } } }
                        if (filters.isNotEmpty()) item("tags") {
                            ActiveFilterTags(filters) { kind ->
                                when (kind) {
                                    ActiveFilter.Kind.SEARCH -> vm.searchText.value = ""
                                    ActiveFilter.Kind.DATE -> vm.dateRange.value = DateRange.ALL
                                    ActiveFilter.Kind.STORE -> vm.storeFilter.value = null
                                }
                            }
                        }
                        if (jobs.isNotEmpty()) item("uploads") {
                            UploadQueuePanel(
                                jobs, onOpen,
                                onCancel = container.importer::cancel,
                                onCancelAll = container.importer::cancelAll,
                                onRetryFailed = container.importer::retryFailed,
                                onClearFinished = container.importer::clearFinished,
                            )
                        }
                        if (ui.all.isEmpty()) item("empty") { EmptyState(::startScan, ::choosePhotos) }
                        else if (ui.filtered.isEmpty()) item("nomatch") { NoMatchState(vm::clearFilters) }

                        if (unreviewed.isNotEmpty()) {
                            stickyHeader("h-review") { SectionHeader("Needs review", unreviewed.size) }
                            items(unreviewed, key = { it.uuid }) { r ->
                                SwipeableReceiptRow(r, reasons, onOpen, ::confirm, ::delete, Modifier.animateItem().padding(horizontal = 14.dp, vertical = 4.dp))
                            }
                        }
                        if (reviewed.isNotEmpty()) {
                            stickyHeader("h-reviewed") { SectionHeader("Reviewed") }
                            items(reviewed, key = { it.uuid }) { r ->
                                SwipeableReceiptRow(r, reasons, onOpen, ::confirm, ::delete, Modifier.animateItem().padding(horizontal = 14.dp, vertical = 4.dp))
                            }
                        }
                        if (ui.deleted.isNotEmpty()) {
                            item("deleted-header") { RecentlyDeletedHeader(ui.deleted.size, showDeleted) { showDeleted = !showDeleted } }
                            if (showDeleted) items(ui.deleted, key = { "deleted-" + it.uuid }) { r ->
                                DeletedRow(r, onRestore = { scope.launch { vm.restore(r.uuid) } }, onDelete = { pendingPurge = r })
                            }
                        }
                    }
                }
            }
        }
    }

    if (showFilters) {
        FilterSheet(
            sheetState = sheetState, ui = ui, range = range, storeFilter = storeFilter,
            onRange = { vm.dateRange.value = it },
            onStore = { vm.storeFilter.value = it },
            onClear = vm::clearFilters,
            // The dialog opens only after the sheet is gone (the iPhone's onDismiss handoff).
            onConfirmAll = { scope.launch { sheetState.hide(); showFilters = false; confirmAll = true } },
            onDone = { scope.launch { sheetState.hide(); showFilters = false } },
            onDismiss = { showFilters = false },
        )
    }
    if (confirmAll) {
        val n = ui.confirmableWithoutFlags.size
        AppConfirmDialog(
            title = ListLogic.confirmAllTitle(n),
            message = "Marks every unreviewed receipt that has no review reasons as reviewed. Receipts with warnings stay in “Needs review”.",
            confirmLabel = "Confirm all",
            onConfirm = { vm.confirmAllWithoutFlags(); confirmAll = false },
            onDismiss = { confirmAll = false },
        )
    }
    pendingPurge?.let { r ->
        AppConfirmDialog(
            title = "Permanently delete this receipt?",
            message = "This removes the receipt, its items and the photo copy on this phone. It cannot be undone.",
            confirmLabel = "Delete permanently",
            destructive = true,
            onConfirm = { vm.purge(r.uuid); pendingPurge = null },
            onDismiss = { pendingPurge = null },
        )
    }
    captureNote?.let { AppAlertDialog("Scan", it) { captureNote = null } }
    if (scannerUnavailable) AppAlertDialog("Document camera not available", ListLogic.SCANNER_UNAVAILABLE) { scannerUnavailable = false }
}
