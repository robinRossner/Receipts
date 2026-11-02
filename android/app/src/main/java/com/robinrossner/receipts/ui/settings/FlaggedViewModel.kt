package com.robinrossner.receipts.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.FlagResolution
import com.robinrossner.receipts.data.FlaggedGroup
import com.robinrossner.receipts.data.FlaggedText
import com.robinrossner.receipts.data.Taxonomy
import com.robinrossner.receipts.data.TaxonomyPath
import com.robinrossner.receipts.data.db.ReceiptSummary
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * State of the "Without a category" screen and of the one-item sheet on a receipt ([onlyDictionaryId] = that item only).
 * Loads on open and again when the flagged count or the receipt list changes (a sync, or a resolve elsewhere).
 * Filing runs here, not in the card, because the card leaves the screen as soon as its group is resolved.
 */
class FlaggedViewModel(private val container: AppContainer, val onlyDictionaryId: String? = null) : ViewModel() {
    private val repo = container.repository

    private val _groups = MutableStateFlow<List<FlaggedGroup>>(emptyList())
    val groups: StateFlow<List<FlaggedGroup>> = _groups

    private val _loaded = MutableStateFlow(false)
    val loaded: StateFlow<Boolean> = _loaded

    private val _notice = MutableStateFlow<String?>(null)
    val notice: StateFlow<String?> = _notice

    /** The merged taxonomy (bundled + added) for every picker and status line. */
    val taxonomy: StateFlow<Taxonomy> = repo.taxonomy

    /** For the receipt link labels. */
    val receipts: StateFlow<List<ReceiptSummary>> = repo.observeReceipts()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    init {
        viewModelScope.launch {
            combine(repo.observeFlaggedCount(), repo.observeReceipts()) { count, list -> count to list.size }
                .collect { load() }
        }
    }

    fun clearNotice() { _notice.value = null }

    private suspend fun load() {
        val new = FlaggedLogic.groups(repo.flaggedItems(), onlyDictionaryId)
        if (new != _groups.value) _groups.value = new
        _loaded.value = true
    }

    /**
     * Files the entries [ids] under [path]: [adding] = add it to the category list first if it is new. [display] says
     * which path the notice names (the canonical spelling once added). [done] gets null when filed, else why not.
     */
    fun file(ids: List<String>, path: TaxonomyPath, adding: Boolean, display: (Taxonomy) -> TaxonomyPath = { path }, done: (String?) -> Unit) {
        viewModelScope.launch {
            val result = if (adding) repo.resolveFlaggedItemsAdding(ids, path) else repo.resolveFlaggedItemsTo(ids, path)
            when (result) {
                is FlagResolution.Resolved -> {
                    _notice.value = FlaggedText.filed(result.count, display(repo.taxonomy.value))
                    load()
                    done(null)
                }
                is FlagResolution.Invalid -> done(result.message)
            }
        }
    }

    /** "Keep in Other": files under Other > Miscellaneous > General, which clears the flag. */
    fun keepInOther(ids: List<String>, done: (String?) -> Unit) = file(ids, Taxonomy.FALLBACK, adding = false, done = done)
}
