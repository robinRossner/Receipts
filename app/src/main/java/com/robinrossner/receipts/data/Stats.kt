package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.db.GroupTotalRow
import com.robinrossner.receipts.data.db.PricePointRow
import com.robinrossner.receipts.data.db.StoreTotalRow
import java.time.LocalDate

// Overview data, computed from the synced receipts, line items and dictionary (the server does no stats).

data class StatsSummary(val total: Double, val categories: List<CategoryStat>)
data class CategoryStat(val category: String, val total: Double, val subcategories: List<SubcategoryStat>)
data class SubcategoryStat(val subcategory: String, val total: Double, val itemGroups: List<ItemGroupStat>)
data class ItemGroupStat(val itemGroup: String, val total: Double)
data class MonthCategoryTotal(val month: String, val category: String, val total: Double)
data class StoreTotal(val store: String, val total: Double)
data class PurchaseRow(
    val date: String?, val store: String?, val translationEn: String?, val nameDe: String?, val quantity: Double,
    val unitPrice: Double, val totalPrice: Double, val receiptId: String, val itemDictionaryId: String,
)
data class PricePoint(val date: LocalDate, val item: String, val unitPrice: Double)

object StatsCalc {
    const val MAX_SERIES = 5
    const val OTHER = "Other"

    /** category > subcategory > item group tree, biggest first at every level. */
    fun summary(rows: List<GroupTotalRow>): StatsSummary {
        val tree = LinkedHashMap<String, LinkedHashMap<String, MutableList<ItemGroupStat>>>()
        for (r in rows) tree.getOrPut(r.category) { LinkedHashMap() }.getOrPut(r.subcategory) { mutableListOf() }.add(ItemGroupStat(r.itemGroup, Rules.round2(r.total)))
        val categories = tree.map { (cat, subs) ->
            val subcategories = subs.map { (name, groups) ->
                SubcategoryStat(name, Rules.round2(groups.sumOf { it.total }), groups.sortedByDescending { it.total })
            }.sortedByDescending { it.total }
            CategoryStat(cat, Rules.round2(subcategories.sumOf { it.total }), subcategories)
        }.sortedByDescending { it.total }
        return StatsSummary(Rules.round2(categories.sumOf { it.total }), categories)
    }

    /** Top categories by total get their own colour; the rest is folded into "Other" (always last). */
    fun seriesNames(monthly: List<MonthCategoryTotal>): List<String> {
        val totals = LinkedHashMap<String, Double>()
        for (m in monthly) totals[m.category] = (totals[m.category] ?: 0.0) + m.total
        val ranked = totals.entries.sortedByDescending { it.value }.map { it.key }.filter { it != OTHER }
        val top = ranked.take(MAX_SERIES)
        return if (ranked.size > MAX_SERIES || totals.containsKey(OTHER)) top + OTHER else top
    }

    /** One entry per month (ascending): the stacked segments, in [series] order. */
    fun stackedBars(monthly: List<MonthCategoryTotal>, series: List<String>): List<Pair<String, List<Pair<String, Double>>>> {
        val top = series.toSet()
        val acc = LinkedHashMap<String, LinkedHashMap<String, Double>>()
        for (m in monthly) {
            val cat = if (m.category in top) m.category else OTHER
            val month = acc.getOrPut(m.month) { LinkedHashMap() }
            month[cat] = (month[cat] ?: 0.0) + m.total
        }
        return acc.toSortedMap().map { (month, segments) -> month to series.mapNotNull { s -> segments[s]?.let { s to it } } }
    }

    /** At most 8 stores, the rest folded into "Other". */
    fun topStores(stores: List<StoreTotalRow>): List<StoreTotal> {
        val top = stores.take(8).map { StoreTotal(it.store, Rules.round2(it.total)) }
        val rest = stores.drop(8).sumOf { it.total }
        return if (rest > 0) top + StoreTotal(OTHER, Rules.round2(rest)) else top
    }

    /** The five most-bought items of the group, as lines over time. */
    fun priceHistory(rows: List<PricePointRow>): List<PricePoint> {
        val counts = rows.groupingBy { it.dictId }.eachCount()
        val top = counts.entries.sortedByDescending { it.value }.take(5).map { it.key }.toSet()
        return rows.mapNotNull { r ->
            if (r.dictId !in top) return@mapNotNull null
            val date = r.date?.take(10)?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: return@mapNotNull null
            PricePoint(date, r.item.orEmpty(), r.unitPrice)
        }
    }

    /** "+12% vs last month"; null when there is no comparison period. */
    fun deltaText(current: Double, previous: Double?, hasPrevious: Boolean, label: String): String? {
        if (!hasPrevious) return null
        if (previous == null || previous <= 0) return if (current > 0 || previous == null) "new vs $label" else null
        val pct = (current - previous) / previous * 100
        if (kotlin.math.abs(pct) < 0.5) return "±0% vs $label"
        return String.format(java.util.Locale.US, "%+.0f%% vs %s", pct, label)
    }
}
