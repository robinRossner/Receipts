package com.robinrossner.receipts.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.ui.components.AppIconButton
import com.robinrossner.receipts.ui.components.AppTopBar
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.background
import com.robinrossner.receipts.ui.theme.AppTheme
import androidx.compose.ui.unit.dp

/**
 * "Without a category" (route `flagged`, reached from Overview). Stub from the UI foundation, only the top bar: the Settings + Flagged owner
 * fills in the body. [onOpenReceipt] opens a receipt and highlights the item (`uuid`, `itemDictionaryId`).
 */
@Composable
fun FlaggedItemsScreen(container: AppContainer, onBack: () -> Unit, onOpenReceipt: (uuid: String, itemDictionaryId: String?) -> Unit) {
    Column(Modifier.fillMaxSize().background(AppTheme.colors.desk)) {
        AppTopBar(
            "Without a category", titleSize = 18f,
            navigationIcon = { AppIconButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", onBack, tint = AppTheme.colors.ink, iconSize = 24.dp) },
        )
        Box(Modifier.fillMaxSize())
    }
}
