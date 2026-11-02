package com.robinrossner.receipts.ui.screens

import androidx.compose.animation.animateContentSize
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.FlagPathDraft
import com.robinrossner.receipts.data.FlaggedGroup
import com.robinrossner.receipts.data.FlaggedItem
import com.robinrossner.receipts.data.FlaggedText
import com.robinrossner.receipts.data.Taxonomy
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.ui.components.AppFlowRow
import com.robinrossner.receipts.ui.components.AppIconButton
import com.robinrossner.receipts.ui.components.AppTopBar
import com.robinrossner.receipts.ui.components.MenuPickerRow
import com.robinrossner.receipts.ui.components.MiniSpinner
import com.robinrossner.receipts.ui.components.NoteBox
import com.robinrossner.receipts.ui.components.PickerGroup
import com.robinrossner.receipts.ui.components.RuleDivider
import com.robinrossner.receipts.ui.components.paperCard
import com.robinrossner.receipts.ui.settings.ChooserSelection
import com.robinrossner.receipts.ui.settings.FlaggedLogic
import com.robinrossner.receipts.ui.settings.FlaggedViewModel
import com.robinrossner.receipts.ui.settings.dismissKeyboardOnDrag
import com.robinrossner.receipts.ui.theme.AppTheme
import com.robinrossner.receipts.ui.theme.EaseOut
import com.robinrossner.receipts.ui.theme.Motion
import kotlinx.coroutines.launch

/**
 * "Without a category" (route `flagged`, reached from Overview): items the categoriser could not file, grouped by the
 * category it suggests. [onOpenReceipt] opens a receipt and highlights the item (`uuid`, `itemDictionaryId`).
 */
@Composable
fun FlaggedItemsScreen(container: AppContainer, onBack: () -> Unit, onOpenReceipt: (uuid: String, itemDictionaryId: String?) -> Unit) {
    val vm: FlaggedViewModel = viewModel(factory = viewModelFactory { initializer { FlaggedViewModel(container) } })
    Column(Modifier.fillMaxSize().background(AppTheme.colors.desk).imePadding()) {
        AppTopBar(
            "Without a category", titleSize = 18f,
            navigationIcon = { AppIconButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", onBack, tint = AppTheme.colors.ink, iconSize = 24.dp) },
        )
        FlaggedContent(vm, openReceipt = { uuid, dictionaryId -> onOpenReceipt(uuid, dictionaryId) }, close = null, modifier = Modifier.weight(1f))
    }
}

/**
 * The body of the screen and of the one-item sheet: title, notice and one card per group. With [close] (the sheet) a `Done`
 * button shows and a resolve closes it; without [openReceipt] the receipts are plain text.
 */
@Composable
internal fun FlaggedContent(
    vm: FlaggedViewModel,
    openReceipt: ((uuid: String, dictionaryId: String) -> Unit)?,
    close: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val c = AppTheme.colors
    val groups by vm.groups.collectAsStateWithLifecycle()
    val loaded by vm.loaded.collectAsStateWithLifecycle()
    val notice by vm.notice.collectAsStateWithLifecycle()
    val taxonomy by vm.taxonomy.collectAsStateWithLifecycle()
    val receipts by vm.receipts.collectAsStateWithLifecycle()

    Column(modifier.fillMaxWidth().background(c.desk).dismissKeyboardOnDrag().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
        Column(Modifier.widthIn(max = 760.dp).fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(FlaggedLogic.title(vm.onlyDictionaryId), style = AppTheme.display(22, c.ink))
                    Text(
                        "Filed under Other > Miscellaneous > General until you decide. One decision fixes every receipt with the item.",
                        style = AppTheme.body(12, color = c.label),
                    )
                }
                if (close != null) {
                    Spacer(Modifier.width(8.dp))
                    FlagButton("Done", close, testTag = "flagDoneButton")
                }
            }
            notice?.let { NoteBox(Icons.Outlined.CheckCircle, it, c.greenText, c.greenBg, testTag = "flagNotice") }
            when {
                !loaded -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) { MiniSpinner(36.dp, strokeWidth = 3.dp) }
                groups.isEmpty() -> Column(Modifier.fillMaxWidth().padding(top = 50.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(Icons.Outlined.Verified, null, Modifier.size(36.dp), tint = c.label)
                    Text("Every item has a category.", Modifier.testTag("flagEmptyState"), style = AppTheme.body(14, color = c.label))
                }
                else -> groups.forEach { group ->
                    key(group.id) { GroupCard(group, vm, taxonomy, receipts, openReceipt, close) }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Buttons

/** The small bordered button of this screen: 13sp, 6dp corners, at least 44dp high. [fill] = `ink`; otherwise `paper` with an `ink` border at 45%. */
@Composable
internal fun FlagButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    fill: Boolean = false,
    enabled: Boolean = true,
    testTag: String? = null,
    content: @Composable RowScope.(color: androidx.compose.ui.graphics.Color) -> Unit,
) {
    val c = AppTheme.colors
    val shape = RoundedCornerShape(6.dp)
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val contentColor = if (fill) c.onInk else c.ink
    Row(
        modifier
            .let { if (testTag != null) it.testTag(testTag) else it }
            .alpha(if (!enabled) 0.4f else if (pressed) 0.7f else 1f)
            .heightIn(min = 44.dp)
            .background(if (fill) c.ink else c.paper, shape)
            .let { if (fill) it else it.border(1.dp, c.ink.copy(alpha = 0.45f), shape) }
            .clickable(interactionSource = source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) { content(contentColor) }
}

@Composable
internal fun FlagButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    fill: Boolean = false,
    enabled: Boolean = true,
    testTag: String? = null,
) = FlagButton(onClick, modifier, fill, enabled, testTag) { color ->
    Text(text, style = AppTheme.body(13, FontWeight.Medium, color), textAlign = TextAlign.Center)
}

// ---------------------------------------------------------------------------------------------------------------------
// One group

@Composable
private fun GroupCard(
    group: FlaggedGroup,
    vm: FlaggedViewModel,
    taxonomy: Taxonomy,
    receipts: List<ReceiptSummary>,
    openReceipt: ((uuid: String, dictionaryId: String) -> Unit)?,
    close: (() -> Unit)?,
) {
    val c = AppTheme.colors
    var draft by remember { mutableStateOf(FlagPathDraft(group.suggestedPath)) }
    var editing by remember { mutableStateOf(group.suggestedPath == null) }
    var chooserIds by remember { mutableStateOf<List<String>?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    fun after(problem: String?) {
        busy = false
        if (problem == null) {
            if (vm.onlyDictionaryId != null) close?.invoke()
        } else {
            message = problem
            if (draft.status(vm.taxonomy.value) is FlagPathDraft.Status.Invalid) editing = true
        }
    }

    fun fileUnder(ids: List<String>, path: com.robinrossner.receipts.data.TaxonomyPath, adding: Boolean) {
        message = null
        busy = true
        vm.file(ids, path, adding, display = { if (adding) it.canonicalPath(path) ?: path else path }, done = ::after)
    }

    fun keepInOther(ids: List<String>) {
        message = null
        busy = true
        vm.keepInOther(ids, ::after)
    }

    Column(Modifier.fillMaxWidth().paperCard().animateContentSize(tween(Motion.FAST, easing = EaseOut)), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        // Header
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(FlaggedLogic.heading(group), style = AppTheme.body(15, FontWeight.SemiBold, c.ink))
                FlaggedLogic.suggestedUnder(group)?.let { Text(it, style = AppTheme.body(12, color = c.inkSoft)) }
            }
            Text(FlaggedText.usage(group.itemCount, group.totalSpend), style = AppTheme.mono(12, color = c.inkSoft))
        }
        // Items
        Column {
            group.items.forEachIndexed { index, item ->
                if (index > 0) RuleDivider(alpha = 0.5f)
                ItemRow(item, multi = group.items.size > 1, enabled = !busy, receipts = receipts, openReceipt = openReceipt,
                    onChoose = { chooserIds = listOf(item.dictionaryId) }, onKeep = { keepInOther(listOf(item.dictionaryId)) })
            }
        }
        if (editing) Editor(draft, { draft = it }, taxonomy)
        message?.let { text ->
            Row(
                Modifier.fillMaxWidth().background(c.redBg, RoundedCornerShape(6.dp)).padding(10.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Top,
            ) {
                Icon(Icons.Filled.Warning, null, Modifier.padding(top = 2.dp).size(12.dp), tint = c.red)
                Text(text, Modifier.testTag("flagResolveMessage"), style = AppTheme.body(13, color = c.red))
            }
        }
        // Actions
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                FlagButton(
                    FlaggedLogic.addLabel(draft, FlaggedLogic.these(group)),
                    onClick = { fileUnder(group.dictionaryIds, draft.path, adding = true) },
                    modifier = Modifier.weight(1f), fill = true, enabled = !busy, testTag = "flagAddButton",
                )
                FlagButton({ editing = !editing }, Modifier.widthIn(min = 44.dp), enabled = !busy, testTag = "flagEditButton") { color ->
                    Icon(
                        if (editing) Icons.Filled.KeyboardArrowUp else Icons.Outlined.Edit,
                        if (editing) "Close editor" else "Edit name and parent", Modifier.size(18.dp), tint = color,
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FlagButton("Choose existing category", { chooserIds = group.dictionaryIds }, Modifier.weight(1f), enabled = !busy, testTag = "flagChooseButton")
                FlagButton("Keep in Other", { keepInOther(group.dictionaryIds) }, Modifier.weight(1f), enabled = !busy, testTag = "flagKeepButton")
            }
        }
    }

    chooserIds?.let { ids ->
        CategoryChooser(
            taxonomy = taxonomy, initial = group.suggestedPath, onDismiss = { chooserIds = null },
            onChoose = { path -> chooserIds = null; fileUnder(ids, path, adding = false) },
        )
    }
}

@Composable
private fun ItemRow(
    item: FlaggedItem,
    multi: Boolean,
    enabled: Boolean,
    receipts: List<ReceiptSummary>,
    openReceipt: ((uuid: String, dictionaryId: String) -> Unit)?,
    onChoose: () -> Unit,
    onKeep: () -> Unit,
) {
    val c = AppTheme.colors
    Column(Modifier.fillMaxWidth().padding(vertical = 7.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f).alignByBaseline(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(item.name, style = AppTheme.body(14, FontWeight.Medium, c.ink))
                item.translationEn?.takeIf { it.isNotEmpty() }?.let { Text(it, style = AppTheme.body(12, color = c.inkSoft)) }
            }
            Text(
                FlaggedText.usage(item.itemCount, item.totalSpend), Modifier.padding(start = 4.dp).alignByBaseline(),
                style = AppTheme.mono(11, color = c.inkSoft), maxLines = 1, softWrap = false,
            )
            if (multi) ItemMenu(item, enabled, onChoose, onKeep)
        }
        ReceiptLinkRow(item, receipts, openReceipt)
    }
}

@Composable
private fun ItemMenu(item: FlaggedItem, enabled: Boolean, onChoose: () -> Unit, onKeep: () -> Unit) {
    val c = AppTheme.colors
    var open by remember { mutableStateOf(false) }
    Box {
        AppIconButton(Icons.Filled.MoreVert, "Options for ${item.name}", { open = true }, Modifier.size(32.dp), tint = c.inkSoft, iconSize = 18.dp, enabled = enabled)
        DropdownMenu(open, { open = false }, containerColor = c.paper) {
            DropdownMenuItem(
                text = { Text("Choose a category for this item…", style = AppTheme.body(14, color = c.ink)) },
                onClick = { open = false; onChoose() },
            )
            DropdownMenuItem(
                text = { Text("Keep this item in Other", style = AppTheme.body(14, color = c.ink)) },
                onClick = { open = false; onKeep() },
            )
        }
    }
}

@Composable
private fun ReceiptLinkRow(item: FlaggedItem, receipts: List<ReceiptSummary>, openReceipt: ((uuid: String, dictionaryId: String) -> Unit)?) {
    val c = AppTheme.colors
    val links = FlaggedLogic.links(item, receipts)
    AppFlowRow(8.dp, 0.dp, Modifier.fillMaxWidth()) {
        links.shown.forEach { link ->
            val base = Modifier.padding(vertical = 6.dp)
            if (openReceipt != null) {
                Text(
                    link.label, base.clickable(role = Role.Button) { openReceipt(link.receiptId, item.dictionaryId) },
                    style = AppTheme.mono(11, color = c.inkSoft).copy(textDecoration = TextDecoration.Underline), maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            } else {
                Text(link.label, base, style = AppTheme.mono(11, color = c.inkSoft), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (links.more > 0) Text("+${links.more} more", Modifier.padding(vertical = 6.dp), style = AppTheme.mono(11, color = c.inkSoft))
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Editor

@Composable
private fun Editor(draft: FlagPathDraft, onChange: (FlagPathDraft) -> Unit, taxonomy: Taxonomy) {
    val c = AppTheme.colors
    Column(
        Modifier.fillMaxWidth().background(c.desk.copy(alpha = 0.5f), RoundedCornerShape(6.dp)).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PathField("Category", draft.category, { onChange(draft.copy(category = it)) }, taxonomy.categoryNames(), "flagCategoryField", "Existing category names")
        PathField(
            "Subcategory", draft.subcategory, { onChange(draft.copy(subcategory = it)) },
            FlaggedLogic.subcategoryOptions(taxonomy, draft), "flagSubcategoryField", "Existing subcategory names",
        )
        PathField("Item group", draft.itemGroup, { onChange(draft.copy(itemGroup = it)) }, null, "flagItemGroupField", null)
        FlaggedLogic.statusLine(draft.status(taxonomy))?.let { Text(it, style = AppTheme.body(12, color = c.inkSoft)) }
    }
}

/** One labelled text field; with [options] a small menu button next to it lists existing names. */
@Composable
private fun PathField(
    title: String,
    text: String,
    onChange: (String) -> Unit,
    options: List<String>?,
    tag: String,
    menuDescription: String?,
) {
    val c = AppTheme.colors
    val focus = LocalFocusManager.current
    var open by remember { mutableStateOf(false) }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.width(80.dp), style = AppTheme.body(12, color = c.inkSoft))
        BasicTextField(
            value = text, onValueChange = onChange,
            modifier = Modifier.weight(1f).height(40.dp).testTag(tag)
                .background(c.field, RoundedCornerShape(5.dp)).border(1.dp, c.rule, RoundedCornerShape(5.dp)).padding(horizontal = 8.dp),
            textStyle = AppTheme.body(13, color = c.ink), singleLine = true, cursorBrush = SolidColor(c.ink),
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }),
            decorationBox = { inner -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.CenterStart) { inner() } },
        )
        if (options != null && menuDescription != null) {
            Box {
                Box(
                    Modifier.size(width = 32.dp, height = 40.dp).clickable(role = Role.Button) { open = true },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.UnfoldMore, menuDescription, Modifier.size(11.dp), tint = c.inkSoft) }
                DropdownMenu(open, { open = false }, containerColor = c.paper) {
                    options.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option, style = AppTheme.body(14, color = c.ink)) },
                            onClick = { open = false; onChange(option) },
                        )
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Chooser sheet

/** Picks an existing category for the items of a card (or one item): a medium-height bottom sheet with three cascading menus. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CategoryChooser(
    taxonomy: Taxonomy,
    initial: com.robinrossner.receipts.data.TaxonomyPath?,
    onDismiss: () -> Unit,
    onChoose: (com.robinrossner.receipts.data.TaxonomyPath) -> Unit,
) {
    val c = AppTheme.colors
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var selection by remember { mutableStateOf(ChooserSelection.start(taxonomy, initial)) }
    val minHeight = (LocalConfiguration.current.screenHeightDp / 2).dp

    fun hide(then: () -> Unit) {
        scope.launch { sheetState.hide() }.invokeOnCompletion { then() }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = c.desk, modifier = Modifier.statusBarsPadding()) {
        Column(Modifier.fillMaxWidth().heightIn(min = minHeight).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("Choose a category", style = AppTheme.display(22, c.ink))
            PickerGroup {
                MenuPickerRow(
                    "Category", selection.category, taxonomy.categoryNames(),
                    { selection = selection.withCategory(taxonomy, it) }, minHeight = 44.dp,
                )
                RuleDivider()
                MenuPickerRow(
                    "Subcategory", selection.subcategory, taxonomy.subcategoryNames(selection.category),
                    { selection = selection.withSubcategory(taxonomy, it) }, minHeight = 44.dp,
                )
                RuleDivider()
                MenuPickerRow(
                    "Item group", selection.itemGroup, taxonomy.itemGroups(selection.category, selection.subcategory),
                    { selection = selection.withItemGroup(it) }, minHeight = 44.dp,
                )
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                FlagButton("Cancel", { hide(onDismiss) }, testTag = "flagChooserCancel")
                Spacer(Modifier.weight(1f))
                FlagButton("File here", { val path = selection.path; hide { onChoose(path) } }, fill = true, enabled = selection.complete, testTag = "flagChooserFile")
            }
        }
    }
}
