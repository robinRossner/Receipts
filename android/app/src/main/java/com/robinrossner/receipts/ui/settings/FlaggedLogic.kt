package com.robinrossner.receipts.ui.settings

import com.robinrossner.receipts.data.FlagPathDraft
import com.robinrossner.receipts.data.FlaggedGroup
import com.robinrossner.receipts.data.FlaggedItem
import com.robinrossner.receipts.data.FlaggedItems
import com.robinrossner.receipts.data.FlaggedText
import com.robinrossner.receipts.data.Taxonomy
import com.robinrossner.receipts.data.TaxonomyPath
import com.robinrossner.receipts.data.db.ReceiptSummary

/** Receipt links of one item: the first few with their label, and how many more there are. */
data class ReceiptLinks(val shown: List<Link>, val more: Int) {
    data class Link(val receiptId: String, val label: String)
}

/** Wording and small rules of the "Without a category" cards, apart from the composables. */
object FlaggedLogic {
    const val MAX_LINKS = 4

    /** The one-item sheet shows only that dictionary entry; the full screen shows all of them. */
    fun groups(all: List<FlaggedItem>, onlyDictionaryId: String?): List<FlaggedGroup> =
        FlaggedItems.group(if (onlyDictionaryId == null) all else all.filter { it.dictionaryId == onlyDictionaryId })

    fun heading(group: FlaggedGroup): String = group.suggestedCategory?.takeIf { it.isNotEmpty() } ?: "No suggestion"

    fun suggestedUnder(group: FlaggedGroup): String? = group.suggestedParent?.takeIf { it.isNotEmpty() }?.let { "Suggested under $it" }

    fun these(group: FlaggedGroup): String = if (group.items.size == 1) "this" else "these"

    fun title(onlyDictionaryId: String?): String = if (onlyDictionaryId == null) "Items without a category" else "Item without a category"

    fun addLabel(draft: FlagPathDraft, these: String): String =
        if (draft.isEmpty) "Add a category and file $these" else "Add “${draft.path.label}” and file $these"

    /** The editor's status line; nothing for an invalid draft (the store explains when the button is pressed). */
    fun statusLine(status: FlagPathDraft.Status): String? = when (status) {
        FlagPathDraft.Status.New -> "New category: added to the list on all your devices."
        FlagPathDraft.Status.Existing -> "This category already exists; the items are filed there."
        is FlagPathDraft.Status.Invalid -> null
    }

    fun links(item: FlaggedItem, receipts: List<ReceiptSummary>): ReceiptLinks =
        ReceiptLinks(
            item.receiptIds.take(MAX_LINKS).map { ReceiptLinks.Link(it, FlaggedText.receiptLabel(it, receipts)) },
            (item.receiptIds.size - MAX_LINKS).coerceAtLeast(0),
        )

    /** Names for the subcategory menu: those of the canonical category named by the typed category, none if it does not exist. */
    fun subcategoryOptions(taxonomy: Taxonomy, draft: FlagPathDraft): List<String> {
        val category = taxonomy.canonicalCategory(draft.path.category) ?: return emptyList()
        return taxonomy.subcategoryNames(category)
    }
}

/** The three values of the category chooser sheet and how they follow each other. */
data class ChooserSelection(val category: String, val subcategory: String, val itemGroup: String) {
    val complete: Boolean get() = category.isNotEmpty() && subcategory.isNotEmpty() && itemGroup.isNotEmpty()
    val path: TaxonomyPath get() = TaxonomyPath(category, subcategory, itemGroup)

    /** A new category starts at its first subcategory and that one's first item group. */
    fun withCategory(taxonomy: Taxonomy, value: String): ChooserSelection {
        val sub = taxonomy.subcategoryNames(value).firstOrNull().orEmpty()
        return ChooserSelection(value, sub, if (sub.isEmpty()) "" else taxonomy.itemGroups(value, sub).firstOrNull().orEmpty())
    }

    /** A new subcategory starts at its first item group (the old group is not kept). */
    fun withSubcategory(taxonomy: Taxonomy, value: String): ChooserSelection =
        copy(subcategory = value, itemGroup = taxonomy.itemGroups(category, value).firstOrNull().orEmpty())

    fun withItemGroup(value: String): ChooserSelection = copy(itemGroup = value)

    companion object {
        /** Starts where the suggestion points when that part of the list exists, else at the top. */
        fun start(taxonomy: Taxonomy, initial: TaxonomyPath?): ChooserSelection {
            val category = initial?.let { taxonomy.canonicalCategory(it.category) } ?: taxonomy.categoryNames().firstOrNull().orEmpty()
            val sub = initial?.let { taxonomy.canonicalSubcategory(it.subcategory, category) } ?: taxonomy.subcategoryNames(category).firstOrNull().orEmpty()
            val group = if (sub.isEmpty()) "" else taxonomy.itemGroups(category, sub).firstOrNull().orEmpty()
            return ChooserSelection(category, sub, group)
        }
    }
}
