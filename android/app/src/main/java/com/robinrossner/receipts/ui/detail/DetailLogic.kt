package com.robinrossner.receipts.ui.detail

import com.robinrossner.receipts.data.Rules
import com.robinrossner.receipts.data.Taxonomy
import com.robinrossner.receipts.data.db.ItemRow
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.components.parseDecimal
import com.robinrossner.receipts.ui.components.trimmedNumber
import java.util.Locale
import kotlin.math.abs

/** What an edit of the store name does when it is committed. */
sealed interface StoreCommit {
    /** The field shows the saved store again (the text was empty). */
    data object Revert : StoreCommit
    data object NoChange : StoreCommit
    data class Update(val store: String) : StoreCommit
}

/** What an edit of the printed total does when it is committed. */
sealed interface TotalCommit {
    /** Not a number: the field shows the saved total again. */
    data object Revert : TotalCommit
    data object NoChange : TotalCommit
    /** [total] null = the field was cleared. */
    data class Update(val total: Double?) : TotalCommit
}

/** The values of a valid "Add missing item" form. */
data class NewItem(val name: String, val quantity: Double, val unitPrice: Double)

/** The three category levels of an item editor. */
data class CategoryChoice(val category: String, val subcategory: String, val itemGroup: String)

/** The pure rules of the receipt detail screen (`ReceiptDetailScreen.swift`, `ReceiptItemRow.swift`). */
object DetailLogic {
    /** Rows of the same product together, in order of first appearance. */
    fun groupItems(items: List<ItemRow>): List<List<ItemRow>> = items.groupBy { it.itemDictionaryId }.values.toList()

    /** Known stores that fit what is typed: not equal to it, containing it (all when empty), at most five. */
    fun storeSuggestions(known: List<String>, typed: String): List<String> {
        val q = typed.trim().lowercase()
        return known.filter { it.lowercase() != q && (q.isEmpty() || it.lowercase().contains(q)) }.take(5)
    }

    fun commitStore(text: String, saved: String?): StoreCommit {
        val t = text.trim()
        return when {
            t.isEmpty() -> StoreCommit.Revert
            t == saved -> StoreCommit.NoChange
            else -> StoreCommit.Update(t)
        }
    }

    fun totalString(total: Double?): String = total?.let { String.format(Locale.US, "%.2f", it) }.orEmpty()

    fun commitTotal(text: String, saved: Double?): TotalCommit {
        val t = text.trim()
        val parsed = if (t.isEmpty()) null else parseDecimal(t)
        return when {
            t.isNotEmpty() && parsed == null -> TotalCommit.Revert
            parsed == saved -> TotalCommit.NoChange
            else -> TotalCommit.Update(parsed)
        }
    }

    /** printed total minus items total, when both are known and differ by more than a cent's rounding; shown as its absolute value. */
    fun difference(computedSum: Double?, typedTotal: String): Double? {
        val sum = computedSum ?: return null
        val typed = parseDecimal(typedTotal) ?: return null
        val d = typed - sum
        return if (abs(d) > 0.004) abs(d) else null
    }

    /** The add form: a name and a price are required, a quantity that does not parse is 1. */
    fun parseNewItem(name: String, qty: String, price: String): NewItem? {
        val n = name.trim()
        val p = parseDecimal(price)
        if (n.isEmpty() || p == null) return null
        return NewItem(n, parseDecimal(qty) ?: 1.0, p)
    }

    /** `€3.49` for quantity x price, `—` when either text does not parse. Accepts a comma. */
    fun previewTotal(qty: String, price: String): String {
        val q = parseDecimal(qty)
        val p = parseDecimal(price)
        return if (q == null || p == null) "—" else fmtMoney(Rules.round2(q * p))
    }

    /** `Dairy › Milk` (empty parts left out). */
    fun categoryPath(subcategory: String?, itemGroup: String?): String =
        listOfNotNull(subcategory, itemGroup).filter { it.isNotEmpty() }.joinToString(" › ")

    /** `1 × €2.49 · Dairy › Milk`. */
    fun summaryLine(quantity: Double, unitPrice: Double, subcategory: String?, itemGroup: String?): String {
        val amount = "${trimmedNumber(quantity)} × ${fmtMoney(unitPrice)}"
        val path = categoryPath(subcategory, itemGroup)
        return if (path.isEmpty()) amount else "$amount · $path"
    }

    /** The note under the pickers once the category was changed; [items] / [receipts] are null until the usage has loaded. */
    fun usageNote(items: Int?, receipts: Int?): String {
        if (items == null || receipts == null) return "This changes the shared dictionary entry for this item."
        val i = if (items == 1) "1 line item" else "$items line items"
        val r = if (receipts == 1) "1 receipt" else "$receipts receipts"
        return "Saving updates the dictionary entry, so it applies to $i across $r."
    }

    /** A new category: first subcategory of it and the first group of that. */
    fun chooseCategory(taxonomy: Taxonomy, category: String): CategoryChoice {
        val sub = taxonomy.subcategoryNames(category).firstOrNull().orEmpty()
        return CategoryChoice(category, sub, taxonomy.itemGroups(category, sub).firstOrNull().orEmpty())
    }

    /** A new subcategory keeps the item group when it also exists there, else takes the first one. */
    fun chooseSubcategory(taxonomy: Taxonomy, category: String, subcategory: String, itemGroup: String): CategoryChoice {
        val groups = taxonomy.itemGroups(category, subcategory)
        return CategoryChoice(category, subcategory, if (itemGroup in groups) itemGroup else groups.firstOrNull().orEmpty())
    }

    /** "Looks good" is not offered while the receipt is being worked on or read by the server. */
    fun looksGoodEnabled(busy: Boolean, stillReading: Boolean): Boolean = !busy && !stillReading
}

/** Zoom and pan of the Photo tab. */
object PhotoZoom {
    const val MIN = 1f
    const val MAX = 8f
    const val STEP = 1.5f
    const val DOUBLE_TAP = 2.5f

    fun clamp(zoom: Float): Float = zoom.coerceIn(MIN, MAX)
    fun zoomIn(zoom: Float): Float = clamp(zoom * STEP)
    fun zoomOut(zoom: Float): Float = clamp(zoom / STEP)
    fun doubleTap(zoom: Float): Float = if (zoom > MIN) MIN else DOUBLE_TAP

    /** One image pixel per dp, at most 8x and at least fit. */
    fun actualSize(imagePixelWidth: Float, fitWidthDp: Float): Float =
        if (imagePixelWidth <= 0f || fitWidthDp <= 0f) MIN else clamp(imagePixelWidth / fitWidthDp)

    /** Fit and 100% are two chips, only one lit: "Fit" at zoom 1, else "100%" when the zoom is the actual size. */
    fun isFit(zoom: Float): Boolean = zoom == MIN
    fun isActualSize(zoom: Float, actualSize: Float): Boolean = zoom != MIN && abs(zoom - actualSize) < 0.001f

    /** How far the picture may be dragged from the centre: half of what it overhangs the pane (0 when it fits). */
    fun maxPan(contentSize: Float, zoom: Float, paneSize: Float): Float = ((contentSize * zoom - paneSize) / 2f).coerceAtLeast(0f)
}
