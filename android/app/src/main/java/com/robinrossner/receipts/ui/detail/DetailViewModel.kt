package com.robinrossner.receipts.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.Rules
import com.robinrossner.receipts.data.Taxonomy
import com.robinrossner.receipts.data.db.ItemRow
import com.robinrossner.receipts.data.db.LocalStatus
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.data.sync.PhotoFetchResult
import com.robinrossner.receipts.data.sync.StringLists
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** What the Photo tab shows. */
sealed interface PhotoUi {
    data object Loading : PhotoUi
    data class Ready(val path: String) : PhotoUi
    data class Note(val text: String) : PhotoUi
}

@OptIn(ExperimentalCoroutinesApi::class)
class DetailViewModel(private val c: AppContainer, val uuid: String) : ViewModel() {
    private val repo = c.repository
    /** The first read of the receipt row has happened (null before that). */
    private data class Loaded(val receipt: ReceiptEntity?)
    private val loadedReceipt: StateFlow<Loaded?> = repo.observeReceipt(uuid).map { Loaded(it) }.stateIn(viewModelScope, SharingStarted.Eagerly, null)
    val receipt: StateFlow<ReceiptEntity?> = loadedReceipt.map { it?.receipt }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    /** False until the receipt row was read; then `receipt == null` means it does not exist (any more). */
    val loaded: StateFlow<Boolean> = loadedReceipt.map { it != null }.stateIn(viewModelScope, SharingStarted.Eagerly, false)
    val items: StateFlow<List<ItemRow>> = repo.observeItems(uuid).stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val knownStores: StateFlow<List<String>> = repo.observeStoresInUse()
        .flatMapLatest { used -> flowOf((Rules.canonicalStoreNames + used).toSet().sorted()) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, Rules.canonicalStoreNames)

    /** The merged category tree (bundled plus user-added), for the item pickers. */
    val taxonomy: StateFlow<Taxonomy> get() = repo.taxonomy

    private val working = MutableStateFlow(0)

    /** True while a retry upload / retry extraction / re-run / discard runs (iOS `busyReceiptIDs`): the form dims and `Looks good` waits. */
    val busy: StateFlow<Boolean> = working.map { it > 0 }.stateIn(viewModelScope, SharingStarted.Eagerly, false)

    private suspend fun <T> busyWhile(block: suspend () -> T): T {
        working.update { it + 1 }
        try { return block() } finally { working.update { it - 1 } }
    }

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

    /** Confirms the receipt; join the job to wait for the write. */
    fun confirm(): Job = viewModelScope.launch { repo.confirm(uuid) }
    fun updateStore(text: String) = viewModelScope.launch { repo.updateStore(uuid, text) }
    fun updateDateTime(date: String, time: String?) = viewModelScope.launch { repo.updateDateTime(uuid, date, time) }
    fun updateTotal(total: Double?) = viewModelScope.launch { repo.updateTotal(uuid, total) }
    /** Soft delete; [onDeleted] runs after the write (it shows the undo bar). */
    fun deleteReceipt(onDeleted: () -> Unit = {}) = viewModelScope.launch { repo.deleteReceipt(uuid); onDeleted() }
    suspend fun restoreReceipt() = repo.restoreReceipt(uuid)
    fun addItem(name: String, qty: Double, price: Double) = viewModelScope.launch { repo.addItem(uuid, name, qty, price) }
    /** Soft delete of a line item; [onDeleted] runs after the write (it shows the undo bar). */
    fun deleteItem(itemUuid: String, onDeleted: () -> Unit = {}) = viewModelScope.launch { repo.deleteLineItem(itemUuid); onDeleted() }
    suspend fun restoreItem(itemUuid: String) = repo.restoreLineItem(itemUuid)

    /**
     * "Save" on an item: its category and translation go to the shared dictionary entry (always, as on the iPhone: this
     * also confirms the category and clears the review flag), then quantity and price to the line item. Join to wait.
     */
    fun saveItem(item: ItemRow, qty: Double, price: Double, category: String, subcategory: String, itemGroup: String, translation: String?): Job =
        viewModelScope.launch {
            repo.correctItem(item.itemDictionaryId, category, subcategory, itemGroup, translation)
            repo.updateLineItem(item.uuid, qty, price)
        }

    suspend fun usage(dictId: String) = repo.dictionaryUsage(dictId)

    fun retryUpload() = viewModelScope.launch { busyWhile { repo.retryUpload(uuid); c.coordinator.syncNow() } }
    fun discardFailedUpload(then: () -> Unit) = viewModelScope.launch { busyWhile { repo.discardFailedUpload(uuid) }; then() }
    val reviewReasons: List<String> get() = StringLists.decode(receipt.value?.reviewReasons)

    /** "Retry extraction" and "Re-run extraction": the server queues it again (the phone has no AI). Failures go to [onError]. */
    fun retryExtraction(onError: (String) -> Unit) = viewModelScope.launch {
        busyWhile {
            try { c.coordinator.retryExtraction(uuid) } catch (e: CancellationException) { throw e } catch (e: Exception) {
                onError("Retrying the extraction failed: ${e.message}")
            }
        }
    }
}
