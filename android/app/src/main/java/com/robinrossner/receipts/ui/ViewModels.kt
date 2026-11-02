package com.robinrossner.receipts.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.CategoryStat
import com.robinrossner.receipts.data.MonthCategoryTotal
import com.robinrossner.receipts.data.PricePoint
import com.robinrossner.receipts.data.PurchaseRow
import com.robinrossner.receipts.data.OverviewCursor
import com.robinrossner.receipts.data.Rules
import com.robinrossner.receipts.data.StatsSummary
import com.robinrossner.receipts.data.StoreTotal
import com.robinrossner.receipts.data.StatsCalc
import com.robinrossner.receipts.data.db.ItemRow
import com.robinrossner.receipts.data.db.LocalStatus
import com.robinrossner.receipts.data.isUnfinished
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.data.sync.PhotoFetchResult
import com.robinrossner.receipts.data.sync.StringLists
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Where a receipt that sync handles stands: waiting for its photo to reach the server, being read there, or failed. */
sealed interface Processing {
    val label: String
    val isActive: Boolean

    data class WaitingForUpload(val error: String?) : Processing {
        override val label get() = "Waiting to upload"
        override val isActive get() = true
    }

    data class UploadFailed(val error: String?) : Processing {
        override val label get() = "Upload failed"
        override val isActive get() = false
    }

    data object Reading : Processing {
        override val label get() = "Reading receipt on the server…"
        override val isActive get() = true
    }

    data class Failed(val error: String?) : Processing {
        override val label get() = "Could not read this receipt"
        override val isActive get() = false
    }

    companion object {
        /** nil = an ordinary finished receipt. */
        fun of(status: String?, error: String?): Processing? = when (status) {
            LocalStatus.PENDING_UPLOAD -> WaitingForUpload(error)
            LocalStatus.UPLOAD_FAILED -> UploadFailed(error)
            "queued", "processing" -> Reading
            "failed" -> Failed(error)
            else -> null
        }
    }
}

val ReceiptSummary.processing get() = Processing.of(extractionStatus, extractionError)
val ReceiptEntity.processing get() = Processing.of(extractionStatus, extractionError)

enum class DateRange(val label: String) {
    ALL("All dates"), THIS_MONTH("This month"), LAST_3_MONTHS("Last 3 months"), THIS_YEAR("This year");

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
    fun delete(uuid: String) = viewModelScope.launch { repo.deleteReceipt(uuid) }
    fun restore(uuid: String) = viewModelScope.launch { repo.restoreReceipt(uuid) }
    fun purge(uuid: String) = viewModelScope.launch { repo.purgeReceipt(uuid) }
    fun confirmAllWithoutFlags() = viewModelScope.launch { repo.confirmAllWithoutFlags(ui.value.confirmableWithoutFlags.map { it.uuid }) }
}

/** What the Photo tab shows. */
sealed interface PhotoUi {
    data object Loading : PhotoUi
    data class Ready(val path: String) : PhotoUi
    data class Note(val text: String) : PhotoUi
}

@OptIn(ExperimentalCoroutinesApi::class)
class DetailViewModel(private val c: AppContainer, val uuid: String) : ViewModel() {
    private val repo = c.repository
    val receipt: StateFlow<ReceiptEntity?> = repo.observeReceipt(uuid).stateIn(viewModelScope, SharingStarted.Eagerly, null)
    val items: StateFlow<List<ItemRow>> = repo.observeItems(uuid).stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val knownStores: StateFlow<List<String>> = repo.observeStoresInUse()
        .flatMapLatest { used -> flowOf((Rules.canonicalStoreNames + used).toSet().sorted()) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, Rules.canonicalStoreNames)

    private val fetchNote = MutableStateFlow<String?>(null)
    private val fetching = MutableStateFlow(false)

    /** Photo tab content: the cached file, or why there is none ("This photo is on your laptop."). */
    val photo: StateFlow<PhotoUi> = combine(receipt, fetchNote, fetching) { r, note, busy ->
        val file = c.paths.resolve(r?.localPhoto)
        when {
            r == null -> PhotoUi.Loading
            file != null && file.isFile -> PhotoUi.Ready(r.localPhoto.orEmpty())
            note != null -> PhotoUi.Note(note)
            r.photoLocation == "archived" -> PhotoUi.Note("This photo is on your laptop.")
            r.photoLocation == "server" -> if (busy || r.extractionStatus == LocalStatus.PENDING_UPLOAD) PhotoUi.Loading else PhotoUi.Note("Loading the photo from the server…")
            r.localPhoto == null -> PhotoUi.Note("This receipt has no photo.")
            else -> PhotoUi.Note("This receipt has no photo.")
        }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, PhotoUi.Loading)

    /** The phone shows its cached copy; if there is none and the server still holds the photo it is downloaded now. */
    fun ensurePhoto() {
        viewModelScope.launch {
            val r = repo.db.receipts().get(uuid) ?: return@launch
            if (r.extractionStatus == LocalStatus.PENDING_UPLOAD || r.extractionStatus == LocalStatus.UPLOAD_FAILED) return@launch
            fetching.value = true
            when (val result = c.coordinator.ensurePhoto(uuid)) {
                is PhotoFetchResult.Cached -> fetchNote.value = null
                PhotoFetchResult.OnLaptop -> { repo.db.receipts().markPhotoArchived(uuid); fetchNote.value = null }
                is PhotoFetchResult.Unavailable -> fetchNote.value = "The photo could not be loaded (${result.message})."
            }
            fetching.value = false
        }
    }

    fun confirm() = viewModelScope.launch { repo.confirm(uuid) }
    fun updateStore(text: String) = viewModelScope.launch { repo.updateStore(uuid, text) }
    fun updateDateTime(date: String, time: String?) = viewModelScope.launch { repo.updateDateTime(uuid, date, time) }
    fun updateTotal(total: Double?) = viewModelScope.launch { repo.updateTotal(uuid, total) }
    fun deleteReceipt() = viewModelScope.launch { repo.deleteReceipt(uuid) }
    fun addItem(name: String, qty: Double, price: Double) = viewModelScope.launch { repo.addItem(uuid, name, qty, price) }
    fun deleteItem(itemUuid: String) = viewModelScope.launch { repo.deleteLineItem(itemUuid) }

    /** "Save" on an item: its category goes to the shared dictionary entry, quantity and price to the line item. */
    fun saveItem(item: ItemRow, qty: Double, price: Double, category: String, subcategory: String, itemGroup: String, translation: String?) {
        viewModelScope.launch {
            if (category != item.category || subcategory != item.subcategory || itemGroup != item.itemGroup || translation != item.translationEn) {
                repo.correctItem(item.itemDictionaryId, category, subcategory, itemGroup, translation)
            }
            repo.updateLineItem(item.uuid, qty, price)
        }
    }

    suspend fun usage(dictId: String) = repo.dictionaryUsage(dictId)

    fun retryUpload() = viewModelScope.launch { repo.retryUpload(uuid); c.coordinator.syncNow() }
    fun discardFailedUpload(then: () -> Unit) = viewModelScope.launch { repo.discardFailedUpload(uuid); then() }
    val reviewReasons: List<String> get() = StringLists.decode(receipt.value?.reviewReasons)

    /** "Retry extraction": the server queues it again (the phone has no AI). */
    fun retryExtraction(onError: (String) -> Unit) = viewModelScope.launch {
        try { c.coordinator.retryExtraction(uuid) } catch (e: Exception) { onError("Retrying the extraction failed: ${e.message}") }
    }
}

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
