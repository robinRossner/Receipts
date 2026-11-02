package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.db.ReceiptSummary
import java.util.Locale

// "No good category": items the server's categoriser could not file are filed under Other > Miscellaneous > General,
// flagged on their dictionary entry with a suggestion for the missing category, and can be resolved later: with an
// existing category, or by adding the (suggested) category to the taxonomy and using it. The flag lives on the
// dictionary entry because the category does: resolving one entry fixes every receipt that uses the item. Overview
// totals are unaffected (the fallback path is a normal category). Port of ReceiptStore+Flagged.swift.

/** One flagged dictionary entry with how often live receipts use it. */
data class FlaggedItem(
    /** The dictionary entry id (pass it to `resolveFlaggedItemsTo`). */
    val dictionaryId: String,
    val name: String,
    val translationEn: String?,
    /** Short name of the category the model found missing, e.g. "Pet Food". */
    val suggestedCategory: String?,
    /** "Category" or "Category > Subcategory" it would go under (existing or new names). */
    val suggestedParent: String?,
    /** Line items on live receipts that use this entry, and what they cost together. */
    val itemCount: Int,
    val totalSpend: Double,
    /** Live receipts that contain it, newest first (to jump to one). */
    val receiptIds: List<String>,
) {
    val suggestedPath: TaxonomyPath? get() = FlaggedItems.path(suggestedCategory, suggestedParent)
}

/** Flagged items that share one suggestion (so one new category can resolve them all). */
data class FlaggedGroup(val id: String, val suggestedCategory: String?, val suggestedParent: String?, val items: List<FlaggedItem>) {
    val suggestedPath: TaxonomyPath? get() = FlaggedItems.path(suggestedCategory, suggestedParent)
    val itemCount: Int get() = items.sumOf { it.itemCount }
    val totalSpend: Double get() = items.sumOf { it.totalSpend }
    val dictionaryIds: List<String> get() = items.map { it.dictionaryId }
}

sealed interface FlagResolution {
    /** `count` dictionary entries were resolved (flag cleared, category set, manual override); for a new path 1 = added, 0 = existed. */
    data class Resolved(val count: Int) : FlagResolution

    /** Nothing changed: the message is user-presentable (invalid or unknown category). */
    data class Invalid(val message: String) : FlagResolution
}

object FlaggedItems {
    /**
     * The taxonomy path a suggestion stands for: a two-part parent gives (category, subcategory, name), a one-part parent
     * (category, name, "General"). Null without a usable suggestion.
     */
    fun path(suggestedCategory: String?, suggestedParent: String?): TaxonomyPath? {
        if (suggestedCategory.isNullOrEmpty() || suggestedParent == null) return null
        val parts = suggestedParent.split(" > ")
        return when (parts.size) {
            1 -> TaxonomyPath(parts[0], suggestedCategory, "General")
            2 -> TaxonomyPath(parts[0], parts[1], suggestedCategory)
            else -> null
        }
    }

    /** Groups by suggestion (case-insensitive); groups with a suggestion first, biggest first, the group without one last. */
    fun group(items: List<FlaggedItem>): List<FlaggedGroup> {
        val buckets = LinkedHashMap<String, MutableList<FlaggedItem>>()
        for (item in items) {
            val key = path(item.suggestedCategory, item.suggestedParent)?.let { "${it.category}|${it.subcategory}|${it.itemGroup}".lowercase(Locale.ROOT) }.orEmpty()
            buckets.getOrPut(key) { mutableListOf() }.add(item)
        }
        val groups = buckets.map { (key, list) -> FlaggedGroup(key, list.first().suggestedCategory, list.first().suggestedParent, list) }
        return groups.sortedWith(
            compareBy<FlaggedGroup> { it.id.isEmpty() }.thenByDescending { it.itemCount }.thenBy { it.id },
        )
    }
}

/** The editable name and parent of a category about to be added. */
data class FlagPathDraft(val category: String, val subcategory: String, val itemGroup: String) {
    constructor(path: TaxonomyPath?) : this(path?.category.orEmpty(), path?.subcategory.orEmpty(), path?.itemGroup.orEmpty())

    sealed interface Status {
        data object New : Status
        data object Existing : Status

        /** Why the store will refuse it (the same rule as [Taxonomy.additionProblem]). */
        data class Invalid(val message: String) : Status
    }

    /** Each level trimmed (spaces and tabs). */
    val path: TaxonomyPath get() = TaxonomyPath(category.trimSpaces(), subcategory.trimSpaces(), itemGroup.trimSpaces())

    val isEmpty: Boolean get() = path.category.isEmpty() && path.subcategory.isEmpty() && path.itemGroup.isEmpty()

    fun status(taxonomy: Taxonomy): Status {
        Taxonomy.additionProblem(path)?.let { return Status.Invalid(it) }
        return if (taxonomy.canonicalPath(path) != null) Status.Existing else Status.New
    }
}

/** The wording of the flagged-items screens. */
object FlaggedText {
    /** `3 purchases · €12.00` */
    fun usage(count: Int, spend: Double): String = "${if (count == 1) "1 purchase" else "$count purchases"} · ${String.format(Locale.US, "€%.2f", spend)}"

    /** What a receipt link says: `ALDI SÜD · 2026-03-01`. A receipt the list does not know goes by its number. */
    fun receiptLabel(receiptId: String, receipts: List<ReceiptSummary>): String {
        val receipt = receipts.firstOrNull { it.uuid == receiptId } ?: return "Receipt #${receiptId.take(8)}"
        return listOfNotNull(receipt.store, receipt.date).filter { it.isNotEmpty() }.joinToString(" · ")
    }

    /** Short message once something was filed. */
    fun filed(count: Int, under: TaxonomyPath): String =
        if (count == 1) "Filed 1 item under ${under.label}." else "Filed $count items under ${under.label}."

    /** What a flagged row in a receipt says: `No good category. Suggested: Pet Food`. */
    fun mark(suggested: String?): String =
        if (suggested.isNullOrEmpty()) "No good category" else "No good category. Suggested: $suggested"
}
