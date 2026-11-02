package com.robinrossner.receipts.ui.detail

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.robinrossner.receipts.data.db.ItemRow
import com.robinrossner.receipts.ui.DetailViewModel
import com.robinrossner.receipts.ui.components.AppIconButton
import com.robinrossner.receipts.ui.components.AppTextField
import com.robinrossner.receipts.ui.components.LocalSnackCenter
import com.robinrossner.receipts.ui.components.MenuPickerRow
import com.robinrossner.receipts.ui.components.OutlineButton
import com.robinrossner.receipts.ui.components.PickerGroup
import com.robinrossner.receipts.ui.components.RuleDivider
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.components.parseDecimal
import com.robinrossner.receipts.ui.components.trimmedNumber
import com.robinrossner.receipts.ui.screens.FlaggedItemMark
import com.robinrossner.receipts.ui.theme.AppTheme
import com.robinrossner.receipts.ui.theme.EaseOut
import com.robinrossner.receipts.ui.theme.Motion
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Locale

private enum class SaveState { IDLE, SAVING, SAVED, BAD }

/**
 * One line item (`ReceiptItemRow.swift`): a summary line that opens the inline editor (quantity x unit price, translation, the
 * three category pickers, Save, delete). Items whose dictionary entry needs review start open. A category correction changes
 * the shared dictionary entry. Texts follow the data when it changes under them (a sync, or another row of the same product).
 */
@Composable
fun ReceiptItemRow(vm: DetailViewModel, item: ItemRow, startOpen: Boolean, modifier: Modifier = Modifier) {
    val colors = AppTheme.colors
    val taxonomy by vm.taxonomy.collectAsStateWithLifecycle()
    val snacks = LocalSnackCenter.current
    val scope = rememberCoroutineScope()

    var open by remember(item.uuid) { mutableStateOf(startOpen) }
    var qty by remember(item.uuid, item.quantity) { mutableStateOf(trimmedNumber(item.quantity)) }
    var price by remember(item.uuid, item.unitPrice) { mutableStateOf(String.format(Locale.US, "%.2f", item.unitPrice)) }
    var translation by remember(item.uuid, item.translationEn) { mutableStateOf(item.translationEn.orEmpty()) }
    var category by remember(item.uuid, item.category) { mutableStateOf(item.category.orEmpty()) }
    var subcategory by remember(item.uuid, item.subcategory) { mutableStateOf(item.subcategory.orEmpty()) }
    var group by remember(item.uuid, item.itemGroup) { mutableStateOf(item.itemGroup.orEmpty()) }
    var state by remember(item.uuid) { mutableStateOf(SaveState.IDLE) }

    val usage by produceState<Pair<Int, Int>?>(null, item.itemDictionaryId, open) {
        if (open) vm.usage(item.itemDictionaryId).let { value = it.items to it.receipts }
    }
    val categoryChanged = category != item.category.orEmpty() || subcategory != item.subcategory.orEmpty() || group != item.itemGroup.orEmpty()
    val previewTotal = DetailLogic.previewTotal(qty, price)

    fun save() {
        scope.launch {
            val q = parseDecimal(qty)
            val p = parseDecimal(price)
            if (q == null || p == null) {
                state = SaveState.BAD
                delay(1_500)
                if (state == SaveState.BAD) state = SaveState.IDLE
                return@launch
            }
            state = SaveState.SAVING
            vm.saveItem(item, q, p, category, subcategory, group, translation.trim()).join()
            state = SaveState.SAVED
            delay(1_500)
            if (state == SaveState.SAVED) state = SaveState.IDLE
        }
    }

    val needsReview = item.dictNeedsReview
    Column(
        modifier
            .fillMaxWidth()
            .padding(vertical = if (needsReview) 4.dp else 0.dp)
            .then(if (needsReview) Modifier.background(colors.redBg, RoundedCornerShape(6.dp)) else Modifier)
            .padding(horizontal = if (needsReview) 8.dp else 0.dp, vertical = 9.dp)
            .animateContentSize(tween(Motion.FAST, easing = EaseOut)),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Summary(item, open, previewTotal) { open = !open }
        if (item.categoryFlagged) FlaggedItemMark(item.itemDictionaryId, item.suggestedCategory)
        if (open) Column(Modifier.padding(top = 2.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                val mono = AppTheme.mono(14)
                AppTextField(
                    qty, { qty = it }, Modifier.width(76.dp).testTag("qtyField").semantics { contentDescription = "Quantity" },
                    textStyle = mono, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
                )
                Text("×", style = mono.copy(color = colors.inkSoft))
                AppTextField(
                    price, { price = it }, Modifier.width(84.dp).testTag("priceField").semantics { contentDescription = "Unit price" },
                    textStyle = mono, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
                )
                Text("=", style = mono.copy(color = colors.inkSoft))
                Text(previewTotal, Modifier.weight(1f), style = mono.copy(fontWeight = FontWeight.SemiBold, color = colors.ink), maxLines = 1, overflow = TextOverflow.Clip)
            }
            AppTextField(
                translation, { translation = it }, Modifier.fillMaxWidth(), textStyle = AppTheme.body(15), placeholder = "Translation",
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            )
            PickerGroup {
                MenuPickerRow("Category", category, taxonomy.categoryNames(), {
                    val c = DetailLogic.chooseCategory(taxonomy, it)
                    category = c.category; subcategory = c.subcategory; group = c.itemGroup
                })
                RuleDivider()
                MenuPickerRow("Subcategory", subcategory, taxonomy.subcategoryNames(category), {
                    val c = DetailLogic.chooseSubcategory(taxonomy, category, it, group)
                    subcategory = c.subcategory; group = c.itemGroup
                })
                RuleDivider()
                MenuPickerRow("Item group", group, taxonomy.itemGroups(category, subcategory), { group = it })
            }
            if (categoryChanged) Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Top) {
                Icon(Icons.Outlined.Info, null, Modifier.padding(top = 1.dp).size(14.dp), tint = colors.inkSoft)
                Text(DetailLogic.usageNote(usage?.first, usage?.second), style = AppTheme.body(12.5f, color = colors.inkSoft))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlineButton(
                    when (state) { SaveState.IDLE -> "Save"; SaveState.SAVING -> "Saving…"; SaveState.SAVED -> "Saved"; SaveState.BAD -> "Bad qty/price" },
                    onClick = ::save,
                    fill = state == SaveState.IDLE,
                    color = if (state == SaveState.BAD) colors.red else colors.ink,
                    enabled = state != SaveState.SAVING,
                    testTag = "saveItemButton",
                )
                Spacer(Modifier.weight(1f))
                AppIconButton(
                    Icons.Outlined.Delete, "Delete item",
                    onClick = { vm.deleteItem(item.uuid) { snacks.show("Item deleted") { vm.restoreItem(item.uuid) } } },
                    modifier = Modifier.offset(x = 10.dp),
                )
            }
        }
    }
}

@Composable
private fun Summary(item: ItemRow, open: Boolean, previewTotal: String, onToggle: () -> Unit) {
    val colors = AppTheme.colors
    val rotation by animateFloatAsState(if (open) 90f else 0f, tween(Motion.FAST, easing = EaseOut), label = "chevron")
    Row(
        Modifier.fillMaxWidth().heightIn(min = 30.dp)
            .clickable(onClickLabel = if (open) "Collapses the editor" else "Opens the editor", onClick = onToggle),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(item.nameDe ?: item.rawText ?: "", style = AppTheme.body(15, FontWeight.SemiBold, colors.ink))
            if (!open) {
                val translation = item.translationEn
                if (!translation.isNullOrEmpty()) Text(translation, style = AppTheme.body(13, color = colors.inkSoft), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    DetailLogic.summaryLine(item.quantity, item.unitPrice, item.subcategory, item.itemGroup),
                    style = AppTheme.mono(11, color = colors.inkSoft), maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Text(
            if (open) previewTotal else fmtMoney(item.totalPrice),
            Modifier.padding(top = 1.dp), style = AppTheme.mono(14, FontWeight.Medium, colors.ink), maxLines = 1,
        )
        Icon(Icons.Filled.KeyboardArrowRight, null, Modifier.padding(top = 4.dp).size(11.dp).rotate(rotation), tint = colors.inkSoft)
    }
}
