package com.robinrossner.receipts.ui.settings

import androidx.lifecycle.ViewModel
import com.robinrossner.receipts.AppContainer

/**
 * State of the "Without a category" screen and of the one-item sheet on a receipt ([onlyDictionaryId] = that item only).
 * Stub from the UI foundation: the Settings + Flagged owner fills it in (groups, loaded, notice, filing actions).
 */
class FlaggedViewModel(private val container: AppContainer, val onlyDictionaryId: String? = null) : ViewModel()
