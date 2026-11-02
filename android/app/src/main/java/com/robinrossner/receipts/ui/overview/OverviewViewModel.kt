package com.robinrossner.receipts.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.CategoryStat
import com.robinrossner.receipts.data.MonthCategoryTotal
import com.robinrossner.receipts.data.OverviewCursor
import com.robinrossner.receipts.data.PricePoint
import com.robinrossner.receipts.data.PurchaseRow
import com.robinrossner.receipts.data.StatsCalc
import com.robinrossner.receipts.data.StatsSummary
import com.robinrossner.receipts.data.StoreTotal
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

enum class RangeMode(val label: String) { MONTH("Month"), YEAR("Year"), CUSTOM("Custom"), ALL("All time") }

data class GroupDetail(val purchases: List<PurchaseRow>, val history: List<PricePoint>)

data class OverviewUi(
    val mode: RangeMode = RangeMode.MONTH,
    val cursor: LocalDate = LocalDate.now(),
    val customStart: LocalDate = LocalDate.now().minusMonths(1),
    val customEnd: LocalDate = LocalDate.now(),
    val summary: StatsSummary? = null,
    val previous: StatsSummary? = null,
    val monthly: List<MonthCategoryTotal> = emptyList(),
    val stores: List<StoreTotal> = emptyList(),
    val openNodes: Set<String> = emptySet(),
    val groupDetails: Map<String, GroupDetail> = emptyMap(),
    val loadingGroups: Set<String> = emptySet(),
) {
    val rangeLabel: String
        get() = when (mode) {
            RangeMode.ALL -> "All time"
            RangeMode.CUSTOM -> "${minOf(customStart, customEnd)} – ${maxOf(customStart, customEnd)}"
            RangeMode.YEAR -> cursor.year.toString()
            RangeMode.MONTH -> DateTimeFormatter.ofPattern("LLLL yyyy", Locale.getDefault()).format(cursor)
        }

    val previousLabel get() = if (mode == RangeMode.YEAR) "last year" else "last month"
    val highlightMonth: String? get() = if (mode == RangeMode.MONTH) cursor.toString().take(7) else null

    private fun monthBounds(d: LocalDate) = d.withDayOfMonth(1).toString() to d.withDayOfMonth(d.lengthOfMonth()).toString()
    private fun yearBounds(d: LocalDate) = d.withDayOfYear(1).toString() to d.withDayOfYear(d.lengthOfYear()).toString()

    /** First/last day of the selected range, "yyyy-MM-dd"; null/null = all time. */
    val range: Pair<String?, String?>
        get() = when (mode) {
            RangeMode.ALL -> null to null
            RangeMode.CUSTOM -> minOf(customStart, customEnd).toString() to maxOf(customStart, customEnd).toString()
            RangeMode.MONTH -> monthBounds(cursor)
            RangeMode.YEAR -> yearBounds(cursor)
        }

    /** The period right before the selected one (month/year only), for "vs last month" deltas. */
    val previousRange: Pair<String, String>?
        get() = when (mode) {
            RangeMode.MONTH -> monthBounds(cursor.minusMonths(1))
            RangeMode.YEAR -> yearBounds(cursor.minusYears(1))
            else -> null
        }

    /** The bar chart covers the 12 months up to the selected one in month view. */
    val chartRange: Pair<String?, String?>
        get() = if (mode == RangeMode.MONTH) monthBounds(cursor.minusMonths(11)).first to monthBounds(cursor).second else range
}

@OptIn(ExperimentalCoroutinesApi::class)
class OverviewViewModel(private val c: AppContainer) : ViewModel() {
    private val repo = c.repository
    private val _ui = MutableStateFlow(OverviewUi())
    val ui: StateFlow<OverviewUi> = _ui

    init {
        viewModelScope.launch {
            // Reload when the range changes or the data changes (a sync, a category corrected on the review page).
            combine(
                _ui.map { Triple(it.mode, it.cursor, it.customStart to it.customEnd) }.distinctUntilChanged(), repo.observeReceiptVersion().distinctUntilChanged(), repo.observeItemVersion().distinctUntilChanged(),
            ) { _, _, _ -> Unit }.collect { load() }
        }
    }

    fun setMode(mode: RangeMode) = _ui.update { it.copy(mode = mode) }
    fun move(delta: Int) = _ui.update {
        val byYear = it.mode == RangeMode.YEAR
        val next = if (byYear) it.cursor.plusYears(delta.toLong()) else it.cursor.plusMonths(delta.toLong())
        // never past the current month / year
        if (delta > 0 && OverviewCursor.isLatest(it.cursor, byYear)) it else it.copy(cursor = next)
    }
    fun setCustomStart(d: LocalDate) = _ui.update { it.copy(customStart = d) }
    fun setCustomEnd(d: LocalDate) = _ui.update { it.copy(customEnd = d) }
    fun reload() = viewModelScope.launch { load() }

    private suspend fun load() {
        val u = _ui.value
        val (start, end) = u.range
        val summary = repo.statsSummary(start, end)
        val previous = u.previousRange?.let { repo.statsSummary(it.first, it.second) }
        val chart = u.chartRange
        val monthly = repo.statsMonthly(chart.first, chart.second)
        val stores = StatsCalc.topStores(repo.statsByStore(start, end))
        // Drill-downs opened earlier belong to the old range.
        _ui.update { it.copy(summary = summary, previous = previous, monthly = monthly, stores = stores, groupDetails = emptyMap()) }
        for (key in _ui.value.openNodes.filter { it.split(KEY_SEP).size == 3 }) loadGroup(key)
    }

    fun toggle(key: String) {
        val opening = key !in _ui.value.openNodes
        _ui.update { it.copy(openNodes = if (opening) it.openNodes + key else it.openNodes - key) }
        if (opening && key.split(KEY_SEP).size == 3 && key !in _ui.value.groupDetails) viewModelScope.launch { loadGroup(key) }
    }

    private suspend fun loadGroup(key: String) {
        val (cat, sub, group) = key.split(KEY_SEP).let { Triple(it[0], it[1], it[2]) }
        _ui.update { it.copy(loadingGroups = it.loadingGroups + key) }
        val (start, end) = _ui.value.range
        val detail = GroupDetail(repo.statsPurchases(cat, sub, group, start, end), repo.statsPriceHistory(cat, sub, group))
        _ui.update { it.copy(groupDetails = it.groupDetails + (key to detail), loadingGroups = it.loadingGroups - key) }
    }

    fun categoryOf(summary: StatsSummary?, name: String): CategoryStat? = summary?.categories?.firstOrNull { it.category == name }

    companion object {
        const val KEY_SEP = " >> "
        fun key(vararg parts: String) = parts.joinToString(KEY_SEP)
    }
}
