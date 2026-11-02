package com.robinrossner.receipts.ui.screens

import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.VerticalDivider
import androidx.compose.ui.draw.clipToBounds
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.Rules
import com.robinrossner.receipts.data.db.ItemRow
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.ui.DetailViewModel
import com.robinrossner.receipts.data.ReviewQueue
import com.robinrossner.receipts.data.isUnfinished
import com.robinrossner.receipts.ui.ListUi
import com.robinrossner.receipts.ui.PhotoUi
import com.robinrossner.receipts.ui.Processing
import com.robinrossner.receipts.ui.components.Paper
import com.robinrossner.receipts.ui.components.PenBox
import com.robinrossner.receipts.ui.components.QuietButton
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.components.parseDecimal
import com.robinrossner.receipts.ui.components.rememberBitmap
import com.robinrossner.receipts.ui.components.trimmedNumber
import com.robinrossner.receipts.ui.processing
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReceiptDetailScreen(
    container: AppContainer, vm: DetailViewModel, list: ListUi, onBack: () -> Unit, onNext: (String) -> Unit,
) {
    val receipt by vm.receipt.collectAsStateWithLifecycle()
    val items by vm.items.collectAsStateWithLifecycle()
    val photo by vm.photo.collectAsStateWithLifecycle()
    val colors = AppTheme.colors
    var photoTab by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var confirmRerun by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(vm.uuid, receipt?.extractionStatus, receipt?.photoLocation) { vm.ensurePhoto() }
    // A receipt that was deleted (here or by sync) leaves the screen.
    LaunchedEffect(receipt?.deletedAt, receipt == null) { if (receipt == null || receipt?.deletedAt != null) onBack() }

    val r = receipt
    Scaffold(
        containerColor = colors.desk,
        topBar = {
            TopAppBar(
                title = { Text(r?.store ?: "Receipt", style = AppTheme.body(16, FontWeight.SemiBold, colors.ink)) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = colors.ink) } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.paper),
            )
        },
        bottomBar = {
            if (r != null) Column {
                HorizontalDivider(color = colors.rule)
                Row(
                    Modifier.fillMaxWidth().background(colors.paper).padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Spacer(Modifier.weight(1f))
                    val reviewed = r.reviewedAt != null
                    Button(
                        onClick = {
                            vm.confirm()
                            ReviewQueue.next(r.uuid, list.all)?.uuid?.let(onNext)
                        },
                        enabled = !reviewed && !r.isUnfinished,
                        modifier = Modifier.testTag("looksGoodButton"),
                        shape = RoundedCornerShape(4.dp),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 30.dp, vertical = 11.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = colors.stampGreen, contentColor = Color.White,
                            disabledContainerColor = colors.stampGreen.copy(alpha = 0.55f), disabledContentColor = Color.White,
                        ),
                    ) { Text(if (reviewed) "Reviewed ✓" else "Looks good", style = AppTheme.body(14, FontWeight.SemiBold)) }
                    Spacer(Modifier.weight(1f))
                    Box {
                        IconButton(onClick = { menu = true }, modifier = Modifier.testTag("moreMenu")) { Icon(Icons.Default.MoreVert, "More actions", tint = colors.ink) }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            // The phone has no AI of its own: the server re-reads a photo it still holds.
                            if (r.photoLocation == "server" && r.processing == null) {
                                DropdownMenuItem(text = { Text("Re-run extraction…") }, onClick = { menu = false; confirmRerun = true })
                            }
                            DropdownMenuItem(text = { Text("Delete receipt…", color = colors.penRed) }, onClick = { menu = false; confirmDelete = true })
                        }
                    }
                }
            }
        },
    ) { padding ->
        if (r == null) {
            Box(Modifier.padding(padding).fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = colors.inkSoft) }
        } else Column(Modifier.padding(padding).fillMaxSize()) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().background(colors.paper).padding(horizontal = 12.dp, vertical = 8.dp)) {
                listOf("Items", "Photo").forEachIndexed { i, label ->
                    SegmentedButton(
                        selected = photoTab == (i == 1), onClick = { photoTab = i == 1 },
                        shape = SegmentedButtonDefaults.itemShape(i, 2), modifier = Modifier.testTag("tab_$label"),
                        colors = SegmentedButtonDefaults.colors(
                            activeContainerColor = colors.ink, activeContentColor = colors.onInk, inactiveContainerColor = colors.paper,
                            inactiveContentColor = colors.ink, activeBorderColor = colors.ink, inactiveBorderColor = colors.rule,
                        ),
                    ) { Text(label, style = AppTheme.body(13)) }
                }
            }
            HorizontalDivider(color = colors.rule)
            if (photoTab) PhotoPane(container, photo) else ItemsPane(vm, r, items, error) { error = it }
        }
    }

    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Delete this receipt?") },
        text = { Text("It moves to “Recently deleted” and can be restored from there.") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; vm.deleteReceipt() }) { Text("Delete", color = colors.penRed) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
    if (confirmRerun) AlertDialog(
        onDismissRequest = { confirmRerun = false },
        title = { Text("Re-run extraction?") },
        text = { Text("The server reads the photo again and marks the receipt as not yet reviewed. If you already edited or confirmed this receipt, the server keeps your version.") },
        confirmButton = { TextButton(onClick = { confirmRerun = false; vm.retryExtraction { error = it } }) { Text("Re-run extraction", color = colors.penRed) } },
        dismissButton = { TextButton(onClick = { confirmRerun = false }) { Text("Cancel") } },
    )
}

// ---------------------------------------------------------------- items

@Composable
private fun ItemsPane(vm: DetailViewModel, r: ReceiptEntity, items: List<ItemRow>, error: String?, setError: (String?) -> Unit) {
    val colors = AppTheme.colors
    val reasons = com.robinrossner.receipts.data.sync.StringLists.decode(r.reviewReasons)
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(12.dp)) {
        Paper(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                r.processing?.let { ProcessingPanel(vm, r, it) }
                error?.let { PenBox { Text(it, style = AppTheme.body(13, color = colors.penRed)) } }
                Header(vm, r)
                if (r.needsReview && reasons.isNotEmpty()) PenBox {
                    reasons.forEach { Text("⚠ $it", style = AppTheme.body(13, color = colors.penRed)) }
                }
                HorizontalDivider(color = colors.rule.copy(alpha = 0.6f))
                // The same product twice stays two rows, bracketed with "2×" like the Mac app.
                items.groupBy { it.itemDictionaryId }.values.forEach { group ->
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            group.forEachIndexed { i, item ->
                                ItemCard(vm, item)
                                if (i < group.lastIndex) HorizontalDivider(color = colors.ink.copy(alpha = 0.06f))
                            }
                        }
                        if (group.size > 1) Row(Modifier.fillMaxHeight().padding(start = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                            VerticalDivider(Modifier.fillMaxHeight(), color = colors.inkSoft)
                            Text("${group.size}×", Modifier.padding(start = 6.dp), style = AppTheme.mono(12, color = colors.inkSoft))
                        }
                    }
                }
                if (items.isEmpty() && r.processing == null) Text("No items.", style = AppTheme.body(13, color = colors.inkSoft))
                AddItemSection(vm, startOpen = Rules.hasSumMismatch(reasons))
                HorizontalDivider(color = colors.rule.copy(alpha = 0.6f))
                Totals(vm, r)
            }
        }
    }
}

@Composable
private fun Header(vm: DetailViewModel, r: ReceiptEntity) {
    val colors = AppTheme.colors
    val known by vm.knownStores.collectAsStateWithLifecycle()
    var text by remember(r.store) { mutableStateOf(r.store.orEmpty()) }
    var focused by remember { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    fun commit() {
        val t = text.trim()
        if (t.isEmpty()) { text = r.store.orEmpty(); return }
        if (t != r.store) vm.updateStore(t)
    }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            BasicTextField(
                value = text, onValueChange = { text = it }, singleLine = true,
                textStyle = AppTheme.display(21.sp, colors.ink).copy(textAlign = TextAlign.Center),
                cursorBrush = SolidColor(colors.ink),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { commit(); focus.clearFocus() }),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp).testTag("storeField")
                    .onFocusChanged { if (focused && !it.isFocused) commit(); focused = it.isFocused },
                decorationBox = { inner ->
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        if (text.isEmpty()) Text("Store", style = AppTheme.display(21.sp, colors.inkSoft))
                        inner()
                    }
                },
            )
            HorizontalDivider(Modifier.padding(horizontal = 32.dp, vertical = 2.dp), color = if (focused) colors.ink else colors.rule)
            val q = text.trim().lowercase()
            val matches = known.filter { it.lowercase() != q && (q.isEmpty() || it.lowercase().contains(q)) }.take(5)
            if (focused && matches.isNotEmpty()) Column(
                Modifier.width(260.dp).clip(RoundedCornerShape(4.dp)).background(colors.paper).border(1.dp, colors.rule, RoundedCornerShape(4.dp)),
            ) {
                matches.forEach { name ->
                    Text(
                        name,
                        Modifier.fillMaxWidth().clickable { text = name; vm.updateStore(name); focus.clearFocus() }.padding(horizontal = 10.dp, vertical = 8.dp),
                        style = AppTheme.body(13, color = colors.ink),
                    )
                }
            }
        }
        DateTimeRow(vm, r)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DateTimeRow(vm: DetailViewModel, r: ReceiptEntity) {
    val colors = AppTheme.colors
    val date = r.date?.take(10)?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
    val time = r.time?.take(5)?.let { runCatching { LocalTime.parse(it) }.getOrNull() }
    var showDate by remember { mutableStateOf(false) }
    var showTime by remember { mutableStateOf(false) }
    val today = LocalDate.now().toString()
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (date != null) QuietButton(date.toString(), Modifier.testTag("dateButton")) { showDate = true }
        else QuietButton("Set date", Modifier.testTag("dateButton")) { vm.updateDateTime(today, r.time) }
        if (time != null) {
            QuietButton(time.format(DateTimeFormatter.ofPattern("HH:mm")), Modifier.testTag("timeButton")) { showTime = true }
            IconButton(onClick = { vm.updateDateTime(r.date ?: today, null) }) { Icon(Icons.Default.Close, "Clear time", tint = colors.inkSoft) }
        } else {
            QuietButton("+ Add time") { vm.updateDateTime(r.date ?: today, LocalTime.now().format(DateTimeFormatter.ofPattern("HH:mm"))) }
        }
    }
    if (showDate && date != null) {
        val state = rememberDatePickerState(initialSelectedDateMillis = date.atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli())
        DatePickerDialog(
            onDismissRequest = { showDate = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { vm.updateDateTime(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate().toString(), r.time?.take(5)) }
                    showDate = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { showDate = false }) { Text("Cancel") } },
        ) { DatePicker(state) }
    }
    if (showTime && time != null) {
        val state = rememberTimePickerState(initialHour = time.hour, initialMinute = time.minute, is24Hour = true)
        AlertDialog(
            onDismissRequest = { showTime = false },
            confirmButton = {
                TextButton(onClick = {
                    vm.updateDateTime(r.date ?: today, "%02d:%02d".format(state.hour, state.minute))
                    showTime = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { showTime = false }) { Text("Cancel") } },
            text = { TimePicker(state) },
        )
    }
}

@Composable
private fun AddItemSection(vm: DetailViewModel, startOpen: Boolean) {
    val colors = AppTheme.colors
    var open by remember { mutableStateOf(startOpen) }
    var name by remember { mutableStateOf("") }
    var qty by remember { mutableStateOf("1") }
    var price by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            if (open) "– Cancel" else "+ Add missing item",
            Modifier.clickable { open = !open }.testTag("addItemToggle").padding(vertical = 4.dp),
            style = AppTheme.body(12, color = colors.inkSoft),
        )
        if (open) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                SmallField(name, { name = it }, "Item name", Modifier.weight(1f))
                SmallField(qty, { qty = it }, "Qty", Modifier.width(64.dp), decimal = true)
                SmallField(price, { price = it }, "Price €", Modifier.width(80.dp), decimal = true)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                error?.let { Text(it, Modifier.weight(1f), style = AppTheme.body(12, color = colors.penRed)) } ?: Spacer(Modifier.weight(1f))
                QuietButton("Add", Modifier.testTag("addItemButton")) {
                    val p = parseDecimal(price)
                    if (name.isBlank() || p == null) { error = "Enter an item name and a price." } else {
                        error = null
                        vm.addItem(name, parseDecimal(qty) ?: 1.0, p)
                        name = ""; price = ""; qty = "1"
                    }
                }
            }
        }
    }
}

@Composable
internal fun SmallField(value: String, onChange: (String) -> Unit, label: String, modifier: Modifier = Modifier, decimal: Boolean = false, tag: String? = null) {
    val colors = AppTheme.colors
    OutlinedTextField(
        value = value, onValueChange = onChange, singleLine = true, modifier = (if (tag != null) modifier.testTag(tag) else modifier),
        placeholder = { Text(label, style = AppTheme.body(12, color = colors.inkSoft)) },
        textStyle = AppTheme.body(13, color = colors.ink),
        keyboardOptions = KeyboardOptions(keyboardType = if (decimal) KeyboardType.Decimal else KeyboardType.Text),
        shape = RoundedCornerShape(4.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = colors.ink, unfocusedBorderColor = colors.rule, focusedContainerColor = colors.card, unfocusedContainerColor = colors.card,
        ),
    )
}

@Composable
private fun Totals(vm: DetailViewModel, r: ReceiptEntity) {
    val colors = AppTheme.colors
    var text by remember(r.total) { mutableStateOf(r.total?.let { String.format(java.util.Locale.US, "%.2f", it) }.orEmpty()) }
    var focused by remember { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    fun commit() {
        val v = if (text.isBlank()) null else parseDecimal(text)
        if (text.isNotBlank() && v == null) { text = r.total?.let { String.format(java.util.Locale.US, "%.2f", it) }.orEmpty(); return }
        if (v != r.total) vm.updateTotal(v)
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text("Items total: ${fmtMoney(r.computedSum)}", Modifier.weight(1f).testTag("itemsTotal"), style = AppTheme.mono(14, color = colors.ink))
        Text("Printed total: €", style = AppTheme.mono(14, color = colors.ink))
        OutlinedTextField(
            value = text, onValueChange = { text = it }, singleLine = true,
            modifier = Modifier.width(96.dp).testTag("totalField").onFocusChanged { if (focused && !it.isFocused) commit(); focused = it.isFocused },
            textStyle = AppTheme.mono(14, color = colors.ink).copy(textAlign = TextAlign.End),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { commit(); focus.clearFocus() }),
            shape = RoundedCornerShape(4.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = colors.ink, unfocusedBorderColor = colors.rule, focusedContainerColor = colors.card, unfocusedContainerColor = colors.card,
            ),
        )
    }
}

@Composable
private fun ProcessingPanel(vm: DetailViewModel, r: ReceiptEntity, p: Processing) {
    val colors = AppTheme.colors
    val body = AppTheme.body(12, color = if (p.isActive) colors.ink else colors.penRed)
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp)).background(colors.penRedBg.copy(alpha = if (p.isActive) 0.5f else 1f))
            .border(1.dp, if (p.isActive) colors.rule else colors.penRed, RoundedCornerShape(4.dp)).padding(12.dp).testTag("processingPanel"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (p.isActive) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 1.5.dp, color = colors.ink)
            Text(p.label, style = AppTheme.body(13, FontWeight.SemiBold, if (p.isActive) colors.ink else colors.penRed))
        }
        when (p) {
            is Processing.WaitingForUpload ->
                Text("The photo is saved on this phone and uploads as soon as the server is reachable." + (p.error?.let { " Last attempt: $it" } ?: ""), style = body)
            is Processing.UploadFailed -> {
                Text((p.error ?: "The server did not accept this photo.") + " Retry, or remove this receipt and add a clearer photo.", style = body)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    QuietButton("Retry upload", danger = true) { vm.retryUpload() }
                    QuietButton("Remove receipt", danger = true) { vm.discardFailedUpload { } }
                }
            }
            Processing.Reading -> Text("The server reads the photo; the result appears here by itself.", style = body)
            is Processing.Failed -> {
                Text((p.error ?: "The server could not read the receipt.") + " Retry it, or fill in the fields below by hand.", style = body)
                if (r.photoLocation == "server") QuietButton("Retry extraction", danger = true, modifier = Modifier.testTag("retryExtraction")) { vm.retryExtraction { } }
            }
        }
    }
}

// ---------------------------------------------------------------- photo

@Composable
private fun PhotoPane(container: AppContainer, photo: PhotoUi) {
    val colors = AppTheme.colors
    Box(Modifier.fillMaxSize().background(colors.desk), contentAlignment = Alignment.Center) {
        when (photo) {
            PhotoUi.Loading -> CircularProgressIndicator(color = colors.inkSoft)
            is PhotoUi.Note -> Text(photo.text, Modifier.padding(32.dp).testTag("photoNote"), style = AppTheme.body(15, color = colors.inkSoft), textAlign = TextAlign.Center)
            is PhotoUi.Ready -> {
                val bitmap = rememberBitmap(container.paths.resolve(photo.path))
                if (bitmap == null) CircularProgressIndicator(color = colors.inkSoft) else ZoomableImage(bitmap)
            }
        }
    }
}

/** Pinch to zoom up to 8x, drag to pan, double tap toggles. */
@Composable
private fun ZoomableImage(bitmap: android.graphics.Bitmap) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    Box(
        Modifier.fillMaxSize().clipToBounds()
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    scale = (scale * zoom).coerceIn(1f, 8f)
                    offset = if (scale == 1f) Offset.Zero else offset + pan
                }
            }
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = { scale = if (scale > 1f) 1f else 2.5f; offset = Offset.Zero })
            },
    ) {
        Image(
            bitmap.asImageBitmap(), "Receipt photo",
            Modifier.fillMaxSize().testTag("receiptPhoto").graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y),
            contentScale = ContentScale.Fit,
        )
    }
}
