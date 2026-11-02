package com.robinrossner.receipts.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.Rules
import com.robinrossner.receipts.data.db.ItemRow
import com.robinrossner.receipts.data.db.LocalStatus
import com.robinrossner.receipts.data.db.ReceiptEntity
import com.robinrossner.receipts.data.sync.PhotoFetchResult
import com.robinrossner.receipts.data.sync.StringLists
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
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
