package com.robinrossner.receipts.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.data.isUnfinished
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate

enum class DateRange(val label: String) {
    ALL("All time"), THIS_MONTH("This month"), LAST_3_MONTHS("Last 3 months"), THIS_YEAR("This year");

    /** First day to show ("yyyy-MM-dd"), null = no limit. */
    fun cutoff(today: LocalDate = LocalDate.now()): String? = when (this) {
        ALL -> null
        THIS_MONTH -> today.withDayOfMonth(1).toString()
        LAST_3_MONTHS -> today.minusMonths(3).toString()
        THIS_YEAR -> today.withDayOfYear(1).toString()
    }
}

data class ListUi(
    val all: List<ReceiptSummary> = emptyList(),
    val filtered: List<ReceiptSummary> = emptyList(),
    val deleted: List<ReceiptSummary> = emptyList(),
    val storesInUse: List<String> = emptyList(),
    val isFiltering: Boolean = false,
) {
    val unreviewed get() = filtered.filter { it.reviewedAt == null }
    val reviewed get() = filtered.filter { it.reviewedAt != null }

    /** Order the list shows rows in (needs review first). */
    val displayOrder get() = unreviewed + reviewed

    /** What "Confirm all without flags" can touch: unreviewed, unflagged receipts the server is not still reading. */
    val confirmableWithoutFlags get() = all.filter { it.reviewedAt == null && !it.needsReview && !it.isUnfinished }
}

@OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
class ListViewModel(private val c: AppContainer) : ViewModel() {
    val searchText = MutableStateFlow("")
    val dateRange = MutableStateFlow(DateRange.ALL)
    val storeFilter = MutableStateFlow<String?>(null)

    private val repo = c.repository
    private val all = repo.observeReceipts()

    private val matches: StateFlow<Set<String>?> = combine(searchText.debounce(200), all) { q, _ -> q }
        .mapLatest { q -> if (q.isBlank()) null else repo.search(q) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val ui: StateFlow<ListUi> = combine(all, repo.observeDeleted(), repo.observeStoresInUse(), matches) { list, deleted, stores, found ->
        Quad(list, deleted, stores, found)
    }.combine(combine(dateRange, storeFilter) { d, s -> d to s }) { (list, deleted, stores, found), (range, store) ->
        val cutoff = range.cutoff()
        val filtered = list.filter { r ->
            (found == null || r.uuid in found) && (store == null || r.store == store) && (cutoff == null || (r.date ?: "") >= cutoff)
        }
        ListUi(list, filtered, deleted, stores.sorted(), found != null || range != DateRange.ALL || store != null)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ListUi())

    private data class Quad<A, B, C, D>(val a: A, val b: B, val c: C, val d: D)

    /** Review reasons of the flagged, unreviewed receipts by id (first reason else "Needs review" on a list row). */
    val reviewReasons: StateFlow<Map<String, List<String>>> = repo.observeReviewReasons()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    fun clearFilters() { searchText.value = ""; dateRange.value = DateRange.ALL; storeFilter.value = null }

    fun refresh() = viewModelScope.launch { c.coordinator.syncNow() }

    // Suspend, and not cancelled with the screen, so a snack can follow the finished write.
    suspend fun delete(uuid: String) = withContext(NonCancellable) { repo.deleteReceipt(uuid) }
    suspend fun restore(uuid: String) = withContext(NonCancellable) { repo.restoreReceipt(uuid) }

    /** "Looks good" by swipe. False when the receipt is still being read (nothing changed). */
    suspend fun confirm(uuid: String): Boolean = withContext(NonCancellable) { repo.confirm(uuid) }
    suspend fun unconfirm(uuid: String) = withContext(NonCancellable) { repo.unconfirm(uuid) }
    fun purge(uuid: String) = viewModelScope.launch { repo.purgeReceipt(uuid) }
    fun confirmAllWithoutFlags() = viewModelScope.launch { repo.confirmAllWithoutFlags(ui.value.confirmableWithoutFlags.map { it.uuid }) }
}
