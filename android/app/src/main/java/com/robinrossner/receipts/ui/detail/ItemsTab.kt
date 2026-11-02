package com.robinrossner.receipts.ui.detail

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
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
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.robinrossner.receipts.data.Rules
import com.robinrossner.receipts.data.db.ItemRow
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.data.sync.StringLists
import com.robinrossner.receipts.ui.DetailViewModel
import com.robinrossner.receipts.ui.Processing
import com.robinrossner.receipts.ui.components.AppIconButton
import com.robinrossner.receipts.ui.components.AppTextField
import com.robinrossner.receipts.ui.components.LocalErrorCenter
import com.robinrossner.receipts.ui.components.MiniSpinner
import com.robinrossner.receipts.ui.components.OutlineButton
import com.robinrossner.receipts.ui.components.ReceiptDateFormat
import com.robinrossner.receipts.ui.components.RuleDivider
import com.robinrossner.receipts.ui.components.fieldBox
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.components.paperCard
import com.robinrossner.receipts.ui.processing
import com.robinrossner.receipts.ui.theme.AppTheme
import com.robinrossner.receipts.ui.theme.EaseOut
import com.robinrossner.receipts.ui.theme.Motion
import com.robinrossner.receipts.ui.theme.appDatePickerColors
import com.robinrossner.receipts.ui.theme.appTimePickerColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset

/** The Items tab: one paper card with the processing panel, header, warnings, item groups, add form and totals. */
@Composable
fun ItemsTab(
    vm: DetailViewModel, r: ReceiptEntity, items: List<ItemRow>, busy: Boolean, highlightItemId: String?,
    onDeleteReceipt: () -> Unit, modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    val reasons = remember(r.reviewReasons) { StringLists.decode(r.reviewReasons) }
    val scroll = rememberScrollState()
    val focus = LocalFocusManager.current
    // Dragging the list puts the keyboard away (iOS: scrollDismissesKeyboard(.interactively)).
    val dismissKeyboard = remember(focus) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.UserInput && available.y != 0f) focus.clearFocus()
                return Offset.Zero
            }
        }
    }

    // The Overview's / Flagged list's `Edit`: scroll to the item group, tint it, and let the tint fade.
    var highlightActive by remember(highlightItemId) { mutableStateOf(highlightItemId != null) }
    val highlightAlpha = animateFloatAsState(if (highlightActive) 1f else 0f, tween(Motion.HIGHLIGHT, easing = EaseOut), label = "highlight")
    val coordinates = remember { arrayOfNulls<LayoutCoordinates>(2) } // viewport, target group
    val targetExists = highlightItemId != null && items.any { it.itemDictionaryId == highlightItemId }
    LaunchedEffect(highlightItemId, targetExists) {
        if (!targetExists) return@LaunchedEffect
        delay(150)
        val viewport = coordinates[0]
        val group = coordinates[1]
        if (viewport != null && group != null && viewport.isAttached && group.isAttached) {
            val center = viewport.localPositionOf(group, Offset.Zero).y + group.size.height / 2f
            scroll.animateScrollTo((scroll.value + center - viewport.size.height / 2f).toInt().coerceIn(0, scroll.maxValue))
        }
        delay(1_600)
        highlightActive = false
    }

    Box(modifier.fillMaxSize()) {
        Box(
            Modifier.fillMaxSize().onGloballyPositioned { coordinates[0] = it }
                .nestedScroll(dismissKeyboard).verticalScroll(scroll)
                .padding(horizontal = 10.dp, vertical = 4.dp),
        ) {
            Column(
                Modifier.fillMaxWidth().alpha(if (busy) 0.45f else 1f).paperCard(),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                r.processing?.let { ProcessingPanel(vm, it) }
                Header(vm, r, onDeleteReceipt)
                if (r.needsReview && reasons.isNotEmpty()) Warnings(reasons)
                if (items.isNotEmpty()) ItemGroups(vm, items, highlightItemId, highlightActive, highlightAlpha, coordinates)
                AddItemSection(vm, startOpen = Rules.hasSumMismatch(reasons))
                Footer(vm, r)
            }
            // While something runs on the receipt the card cannot be touched.
            if (busy) Box(
                Modifier.matchParentSize().clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
            )
        }
        if (busy) BusyBox(Modifier.align(Alignment.Center))
    }
}

// ---------------------------------------------------------------- header

/** A text field without a box: [CenterStart] or [CenterEnd] aligned text and placeholder, at least [minHeight] high. */
@Composable
private fun PlainField(
    value: String,
    onValueChange: (String) -> Unit,
    textStyle: TextStyle,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    align: TextAlign = TextAlign.Start,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    val colors = AppTheme.colors
    val style = textStyle.copy(textAlign = align)
    BasicTextField(
        value, onValueChange, modifier, textStyle = style, singleLine = true, cursorBrush = SolidColor(colors.ink),
        keyboardOptions = keyboardOptions, keyboardActions = keyboardActions,
        decorationBox = { inner ->
            Box(
                Modifier.fillMaxWidth(),
                contentAlignment = when (align) { TextAlign.End -> Alignment.CenterEnd; TextAlign.Center -> Alignment.Center; else -> Alignment.CenterStart },
            ) {
                if (value.isEmpty() && placeholder != null) Text(placeholder, style = style.copy(color = colors.inkSoft), maxLines = 1)
                inner()
            }
        },
    )
}

@Composable
private fun Header(vm: DetailViewModel, r: ReceiptEntity, onDeleteReceipt: () -> Unit) {
    val colors = AppTheme.colors
    val known by vm.knownStores.collectAsStateWithLifecycle()
    val savedStore by rememberUpdatedState(r.store)
    var text by remember { mutableStateOf(r.store.orEmpty()) }
    // The latest text, readable from focus callbacks that were created before the last keystroke.
    val latest = remember { arrayOf(r.store.orEmpty()) }
    fun setText(value: String) { text = value; latest[0] = value }
    LaunchedEffect(r.store) { setText(r.store.orEmpty()) }
    var focused by remember { mutableStateOf(false) }
    val focus = LocalFocusManager.current

    fun commit() {
        when (val c = DetailLogic.commitStore(latest[0], savedStore)) {
            StoreCommit.Revert -> setText(savedStore.orEmpty())
            StoreCommit.NoChange -> {}
            is StoreCommit.Update -> vm.updateStore(c.store)
        }
    }
    // Leaving the screen with a pending edit keeps it.
    DisposableEffect(Unit) { onDispose { commit() } }

    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.fillMaxWidth()) {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                PlainField(
                    text, ::setText, AppTheme.display(24, colors.ink),
                    Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = 44.dp).testTag("storeField")
                        .onFocusChanged { if (focused && !it.isFocused) commit(); focused = it.isFocused },
                    placeholder = "Store", align = TextAlign.Center,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }),
                )
                val matches = DetailLogic.storeSuggestions(known, text)
                if (focused && matches.isNotEmpty()) Column(Modifier.fillMaxWidth().padding(horizontal = 44.dp).padding(top = 4.dp).fieldBox()) {
                    matches.forEachIndexed { i, name ->
                        Box(
                            Modifier.fillMaxWidth().heightIn(min = 40.dp)
                                .clickable { setText(name); commit(); focus.clearFocus() }.padding(horizontal = 12.dp),
                            contentAlignment = Alignment.CenterStart,
                        ) { Text(name, style = AppTheme.body(15, color = colors.ink)) }
                        if (i < matches.lastIndex) RuleDivider()
                    }
                }
            }
            AppIconButton(
                Icons.Outlined.Delete, "Delete receipt", onDeleteReceipt,
                Modifier.align(Alignment.TopEnd).offset(x = 8.dp), tint = colors.inkSoft, iconSize = 15.dp,
            )
        }
        DateTimeRow(vm, r)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DateTimeRow(vm: DetailViewModel, r: ReceiptEntity) {
    val date = ReceiptDateFormat.parseDate(r.date)
    val time = ReceiptDateFormat.parseTime(r.time)
    var showDate by remember { mutableStateOf(false) }
    var showTime by remember { mutableStateOf(false) }
    val today = ReceiptDateFormat.date(LocalDate.now())
    val storedTime = r.time?.take(5)

    /** Saves date and time when they differ from what is stored. Without a date nothing is written, as on the iPhone (`saveDateTime`). */
    fun save(newDate: String?, newTime: String?) {
        if (newDate == null) return
        if (newDate != r.date || newTime != storedTime) vm.updateDateTime(newDate, newTime)
    }

    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
        if (date != null) {
            val text = ReceiptDateFormat.date(date)
            Pill(text, "Date $text", "dateButton") { showDate = true }
        } else OutlineButton("Set date", { save(today, storedTime) })
        if (time != null) {
            val text = ReceiptDateFormat.time(time)
            Pill(text, "Time $text", "timeButton") { showTime = true }
            Box(
                Modifier.size(width = 32.dp, height = 44.dp).clickable { save(r.date, null) },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Cancel, "Clear time", Modifier.size(18.dp), tint = AppTheme.colors.inkSoft) }
        } else OutlineButton("+ Add time", { save(r.date, ReceiptDateFormat.time(LocalTime.now())) })
    }

    if (showDate && date != null) {
        val state = rememberDatePickerState(initialSelectedDateMillis = date.atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli())
        DatePickerDialog(
            onDismissRequest = { showDate = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { save(java.time.Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate().toString(), storedTime) }
                    showDate = false
                }) { DialogButtonText("OK") }
            },
            dismissButton = { TextButton(onClick = { showDate = false }) { DialogButtonText("Cancel") } },
            colors = appDatePickerColors(),
        ) { DatePicker(state, colors = appDatePickerColors()) }
    }
    if (showTime && time != null) {
        val state = rememberTimePickerState(initialHour = time.hour, initialMinute = time.minute, is24Hour = true)
        AlertDialog(
            onDismissRequest = { showTime = false },
            containerColor = AppTheme.colors.paper,
            confirmButton = {
                TextButton(onClick = {
                    save(r.date ?: today, String.format(java.util.Locale.ROOT, "%02d:%02d", state.hour, state.minute))
                    showTime = false
                }) { DialogButtonText("OK") }
            },
            dismissButton = { TextButton(onClick = { showTime = false }) { DialogButtonText("Cancel") } },
            text = { TimePicker(state, colors = appTimePickerColors()) },
        )
    }
}

@Composable
private fun DialogButtonText(text: String) = Text(text, style = AppTheme.body(14, FontWeight.Medium, AppTheme.colors.ink))

@Composable
private fun Pill(text: String, description: String, tag: String, onClick: () -> Unit) {
    val colors = AppTheme.colors
    val shape = RoundedCornerShape(8.dp)
    Box(
        Modifier.heightIn(min = 44.dp).testTag(tag)
            .background(colors.field, shape).border(1.dp, colors.rule, shape)
            .clickable(onClick = onClick).semantics(mergeDescendants = true) { contentDescription = description }
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) { Text(text, style = AppTheme.mono(14, FontWeight.Medium, colors.ink), maxLines = 1) }
}

// ---------------------------------------------------------------- warnings and processing

@Composable
private fun Warnings(reasons: List<String>) {
    val colors = AppTheme.colors
    Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).background(colors.redBg)) {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            reasons.forEach { reason ->
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.Top) {
                    Icon(Icons.Filled.Warning, null, Modifier.padding(top = 2.dp).size(12.dp), tint = colors.red)
                    Text(reason, style = AppTheme.body(14, color = colors.red))
                }
            }
        }
        Box(Modifier.matchParentSize()) { Box(Modifier.width(3.dp).fillMaxHeight().background(colors.red)) }
    }
}

@Composable
private fun ProcessingPanel(vm: DetailViewModel, p: Processing) {
    val colors = AppTheme.colors
    val active = p.isActive
    val title = if (active) colors.ink else colors.red
    val textColor = if (active) colors.inkSoft else colors.red
    Column(
        Modifier.fillMaxWidth().testTag("processingPanel")
            .background(if (active) colors.desk.copy(alpha = 0.5f) else colors.redBg, RoundedCornerShape(6.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (active) MiniSpinner(16.dp, color = title, strokeWidth = 2.dp) else Icon(Icons.Filled.Error, null, Modifier.size(16.dp), tint = title)
            Text(p.label, style = AppTheme.body(15, FontWeight.SemiBold, title))
        }
        val message = when (p) {
            is Processing.WaitingForUpload ->
                "The photo is saved on this phone and uploads as soon as the server is reachable." + (p.error?.let { " Last attempt: $it" } ?: "")
            Processing.Reading -> "The server reads the photo; the result appears here by itself."
            is Processing.UploadFailed -> (p.error ?: "The server did not accept this photo.") + " Retry, or remove this receipt and add a clearer photo."
            is Processing.Failed -> (p.error ?: "The server could not read the receipt.") + " Retry it, or fill in the fields below by hand."
        }
        Text(message, style = AppTheme.body(13.5f, color = textColor))
        val errors = LocalErrorCenter.current
        when (p) {
            is Processing.UploadFailed -> Row(Modifier.padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlineButton("Retry upload", { vm.retryUpload() }, fill = true)
                // The receipt disappears, which takes this screen away.
                OutlineButton("Remove receipt", { vm.discardFailedUpload {} }, color = colors.red)
            }
            is Processing.Failed -> Row(Modifier.padding(top = 2.dp)) {
                OutlineButton("Retry extraction", { vm.retryExtraction { errors.show(it) } }, fill = true, testTag = "retryExtraction")
            }
            else -> {}
        }
    }
}

@Composable
private fun BusyBox(modifier: Modifier = Modifier) {
    val colors = AppTheme.colors
    Row(
        modifier
            .shadow(8.dp, RoundedCornerShape(8.dp), ambientColor = Color.Black.copy(alpha = 0.15f), spotColor = Color.Black.copy(alpha = 0.15f))
            .paperCard(18.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        MiniSpinner(20.dp, strokeWidth = 2.dp)
        Text("Working…", style = AppTheme.body(15, FontWeight.Medium, colors.ink))
    }
}

// ---------------------------------------------------------------- item groups

@Composable
private fun ItemGroups(
    vm: DetailViewModel,
    items: List<ItemRow>,
    highlightItemId: String?,
    highlightActive: Boolean,
    highlightAlpha: State<Float>,
    coordinates: Array<LayoutCoordinates?>,
) {
    val colors = AppTheme.colors
    Column(Modifier.fillMaxWidth()) {
        DetailLogic.groupItems(items).forEach { group ->
            val groupId = group.first().itemDictionaryId
            val highlighted = groupId == highlightItemId
            key(groupId) {
                val multi = group.size > 1
                Row(
                    Modifier.fillMaxWidth()
                        .then(if (highlighted) Modifier.onGloballyPositioned { coordinates[1] = it } else Modifier)
                        .drawBehind {
                            if (highlighted) drawRoundRect(colors.redBg.copy(alpha = colors.redBg.alpha * highlightAlpha.value), cornerRadius = CornerRadius(6.dp.toPx()))
                        }
                        .then(if (multi) Modifier.height(IntrinsicSize.Min) else Modifier),
                    horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        group.forEachIndexed { i, item ->
                            key(item.uuid) {
                                ReceiptItemRow(vm, item, startOpen = item.dictNeedsReview || (highlighted && highlightActive))
                            }
                            if (i < group.lastIndex) RuleDivider(alpha = 0.5f)
                        }
                    }
                    if (multi) Row(Modifier.fillMaxHeight(), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.width(1.dp).fillMaxHeight().background(colors.inkSoft))
                        Text("${group.size}×", Modifier.padding(start = 6.dp), style = AppTheme.mono(12, FontWeight.Medium, colors.inkSoft))
                    }
                }
                RuleDivider()
            }
        }
    }
}

// ---------------------------------------------------------------- add item

@Composable
private fun AddItemSection(vm: DetailViewModel, startOpen: Boolean) {
    val colors = AppTheme.colors
    // Kept while the Photo tab is shown.
    var open by rememberSaveable { mutableStateOf(startOpen) }
    var name by rememberSaveable { mutableStateOf("") }
    var qty by rememberSaveable { mutableStateOf("1") }
    var price by rememberSaveable { mutableStateOf("") }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    var adding by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun add() {
        val item = DetailLogic.parseNewItem(name, qty, price)
        if (item == null) { error = "Enter an item name and a price."; return }
        error = null
        adding = true
        scope.launch {
            vm.addItem(item.name, item.quantity, item.unitPrice).join()
            name = ""; qty = "1"; price = ""
            adding = false
        }
    }

    Column(Modifier.fillMaxWidth().animateContentSize(tween(Motion.FAST, easing = EaseOut)), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(
            Modifier.heightIn(min = 44.dp).testTag("addItemToggle").clickable { open = !open; error = null },
            contentAlignment = Alignment.CenterStart,
        ) { Text(if (open) "– Cancel" else "+ Add missing item", style = AppTheme.body(14, FontWeight.Medium, colors.ink)) }
        if (open) {
            AppTextField(name, { name = it }, Modifier.fillMaxWidth(), textStyle = AppTheme.body(15), placeholder = "Item name")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                val decimal = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done)
                AppTextField(qty, { qty = it }, Modifier.width(72.dp), textStyle = AppTheme.mono(14), placeholder = "Qty", keyboardOptions = decimal)
                AppTextField(price, { price = it }, Modifier.weight(1f), textStyle = AppTheme.mono(14), placeholder = "Price €", keyboardOptions = decimal)
                OutlineButton(if (adding) "Adding…" else "Add", ::add, fill = true, enabled = !adding, testTag = "addItemButton")
            }
            error?.let { Text(it, style = AppTheme.body(13, color = colors.red)) }
        }
    }
}

// ---------------------------------------------------------------- footer

@Composable
private fun Footer(vm: DetailViewModel, r: ReceiptEntity) {
    val colors = AppTheme.colors
    val savedTotal by rememberUpdatedState(r.total)
    var text by remember { mutableStateOf(DetailLogic.totalString(r.total)) }
    val latest = remember { arrayOf(text) }
    fun setText(value: String) { text = value; latest[0] = value }
    var focused by remember { mutableStateOf(false) }
    // External updates do not overwrite what is being typed.
    LaunchedEffect(r.total) { if (!focused) setText(DetailLogic.totalString(r.total)) }
    val focus = LocalFocusManager.current

    fun commit() {
        when (val c = DetailLogic.commitTotal(latest[0], savedTotal)) {
            TotalCommit.Revert -> setText(DetailLogic.totalString(savedTotal))
            TotalCommit.NoChange -> {}
            is TotalCommit.Update -> vm.updateTotal(c.total)
        }
    }
    DisposableEffect(Unit) { onDispose { commit() } }

    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        RuleDivider()
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Items total:", style = AppTheme.body(14, color = colors.inkSoft))
            Spacer(Modifier.weight(1f))
            Text(fmtMoney(r.computedSum), Modifier.testTag("itemsTotal"), style = AppTheme.mono(15, FontWeight.SemiBold, colors.ink))
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Printed total:", style = AppTheme.body(14, color = colors.inkSoft))
            Spacer(Modifier.weight(1f))
            Row(
                Modifier.fieldBox(focused).padding(horizontal = 10.dp).heightIn(min = 40.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("€", style = AppTheme.mono(14, color = colors.inkSoft))
                PlainField(
                    text, ::setText, AppTheme.mono(14, FontWeight.Medium, colors.ink),
                    Modifier.width(66.dp).testTag("printedTotalField").semantics { contentDescription = "Printed total" }
                        .onFocusChanged { if (focused && !it.isFocused) commit(); focused = it.isFocused },
                    placeholder = "0.00", align = TextAlign.End,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }),
                )
            }
        }
        DetailLogic.difference(r.computedSum, text)?.let { difference ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Difference:", style = AppTheme.body(14, FontWeight.Medium, colors.red))
                Spacer(Modifier.weight(1f))
                Text(fmtMoney(difference), style = AppTheme.mono(14, FontWeight.SemiBold, colors.red))
            }
        }
    }
}
