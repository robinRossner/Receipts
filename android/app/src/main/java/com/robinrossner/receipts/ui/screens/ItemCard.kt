package com.robinrossner.receipts.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.AppContainer
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.robinrossner.receipts.ReceiptsApp
import com.robinrossner.receipts.data.Rules
import com.robinrossner.receipts.data.db.ItemRow
import com.robinrossner.receipts.ui.DetailViewModel
import com.robinrossner.receipts.ui.components.QuietButton
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.components.parseDecimal
import com.robinrossner.receipts.ui.components.trimmedNumber
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.delay

/**
 * An editable line item: quantity x unit price, the English translation, and the three category pickers
 * (category > subcategory > item group). A category correction changes the shared dictionary entry.
 */
@Composable
fun ItemCard(vm: DetailViewModel, item: ItemRow) {
    val colors = AppTheme.colors
    val taxonomy by (LocalContext.current.applicationContext as ReceiptsApp).container.repository.taxonomy.collectAsStateWithLifecycle()
    var qty by remember(item.uuid, item.quantity) { mutableStateOf(trimmedNumber(item.quantity)) }
    var price by remember(item.uuid, item.unitPrice) { mutableStateOf(String.format(java.util.Locale.US, "%.2f", item.unitPrice)) }
    var translation by remember(item.uuid, item.translationEn) { mutableStateOf(item.translationEn.orEmpty()) }
    var category by remember(item.uuid, item.category) { mutableStateOf(item.category.orEmpty()) }
    var subcategory by remember(item.uuid, item.subcategory) { mutableStateOf(item.subcategory.orEmpty()) }
    var group by remember(item.uuid, item.itemGroup) { mutableStateOf(item.itemGroup.orEmpty()) }
    var state by remember(item.uuid) { mutableStateOf(SaveState.IDLE) }
    val usage by produceState<Pair<Int, Int>?>(null, item.itemDictionaryId) { vm.usage(item.itemDictionaryId).let { value = it.items to it.receipts } }
    val categoryChanged = category != item.category.orEmpty() || subcategory != item.subcategory.orEmpty() || group != item.itemGroup.orEmpty()
    val previewTotal = run {
        val q = parseDecimal(qty)
        val p = parseDecimal(price)
        if (q == null || p == null) "—" else fmtMoney(Rules.round2(q * p))
    }
    LaunchedEffect(state) { if (state == SaveState.FAILED || state == SaveState.SAVED) { delay(1800); state = SaveState.IDLE } }

    Column(
        Modifier.fillMaxWidth().let { if (item.dictNeedsReview) it.clip(RoundedCornerShape(4.dp)).background(colors.redBg).padding(10.dp) else it },
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(item.nameDe.orEmpty(), style = AppTheme.body(14, FontWeight.SemiBold, colors.ink))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            SmallField(qty, { qty = it }, "Qty", Modifier.width(72.dp), decimal = true, tag = "qtyField")
            Text("×", style = AppTheme.mono(12, color = colors.inkSoft))
            SmallField(price, { price = it }, "Price", Modifier.width(92.dp), decimal = true, tag = "priceField")
            Text("=", style = AppTheme.mono(12, color = colors.inkSoft))
            Text(previewTotal, style = AppTheme.mono(12, FontWeight.SemiBold, colors.ink))
        }
        SmallField(translation, { translation = it }, "Translation", Modifier.fillMaxWidth())
        PickerRow("Category", category, taxonomy.categoryNames()) {
            category = it
            subcategory = taxonomy.subcategoryNames(it).firstOrNull().orEmpty()
            group = taxonomy.itemGroups(it, subcategory).firstOrNull().orEmpty()
        }
        PickerRow("Subcategory", subcategory, taxonomy.subcategoryNames(category)) {
            subcategory = it
            group = taxonomy.itemGroups(category, it).firstOrNull().orEmpty()
        }
        PickerRow("Item group", group, taxonomy.itemGroups(category, subcategory)) { group = it }
        if (categoryChanged) {
            val u = usage
            val text = if (u == null) "This changes the shared dictionary entry for this item." else {
                val items = if (u.first == 1) "1 line item" else "${u.first} line items"
                val receipts = if (u.second == 1) "1 receipt" else "${u.second} receipts"
                "Saving updates the dictionary entry, so it applies to $items across $receipts."
            }
            Text("ⓘ $text", style = AppTheme.body(11, color = colors.inkSoft))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            QuietButton(
                when (state) { SaveState.IDLE -> "Save"; SaveState.SAVED -> "Saved"; SaveState.FAILED -> "Bad qty/price" },
                Modifier.testTag("saveItemButton"),
            ) {
                val q = parseDecimal(qty)
                val p = parseDecimal(price)
                if (q == null || p == null) state = SaveState.FAILED else {
                    vm.saveItem(item, q, p, category, subcategory, group, translation.trim().ifEmpty { null })
                    state = SaveState.SAVED
                }
            }
            IconButton(onClick = { vm.deleteItem(item.uuid) }) { Icon(Icons.Default.DeleteOutline, "Delete item", tint = colors.inkSoft) }
            Spacer(Modifier.weight(1f))
        }
    }
}

private enum class SaveState { IDLE, SAVED, FAILED }

/** A titled row: label left, current value right; tapping opens the choices. */
@Composable
private fun PickerRow(title: String, value: String, options: List<String>, onSelect: (String) -> Unit) {
    val colors = AppTheme.colors
    var open by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 8.dp).testTag("picker_$title"),
            horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, style = AppTheme.body(12, color = colors.inkSoft))
            Text("$value  ▾", style = AppTheme.body(12, FontWeight.Medium, colors.ink))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { o -> DropdownMenuItem(text = { Text((if (o == value) "✓ " else "    ") + o) }, onClick = { open = false; onSelect(o) }) }
        }
    }
}
