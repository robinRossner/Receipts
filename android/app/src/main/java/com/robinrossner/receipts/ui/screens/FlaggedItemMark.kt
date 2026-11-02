package com.robinrossner.receipts.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.LabelOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.ReceiptsApp
import com.robinrossner.receipts.data.FlaggedText
import com.robinrossner.receipts.ui.settings.FlaggedViewModel
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.launch

/**
 * The red "No good category" line under a receipt item whose category is flagged, with the "Sort out…" button that opens the
 * one-item sheet (the same cards as the "Without a category" screen, filtered to this item, without links to receipts).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FlaggedItemMark(dictionaryId: String, suggestedCategory: String?, modifier: Modifier = Modifier) {
    val c = AppTheme.colors
    var open by remember { mutableStateOf(false) }
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.AutoMirrored.Outlined.LabelOff, null, Modifier.size(12.dp), tint = c.red)
        Text(FlaggedText.mark(suggestedCategory), Modifier.weight(1f, fill = false).testTag("flagMark"), style = AppTheme.body(12, color = c.red))
        Spacer(Modifier.width(4.dp))
        Box(Modifier.heightIn(min = 36.dp).clickable(role = Role.Button) { open = true }.testTag("flagSortOutButton"), contentAlignment = Alignment.Center) {
            Text("Sort out…", style = AppTheme.body(12, FontWeight.SemiBold, c.red).copy(textDecoration = TextDecoration.Underline))
        }
    }
    if (open) {
        val container = (LocalContext.current.applicationContext as ReceiptsApp).container
        FlaggedSheet(container, dictionaryId, onClose = { open = false })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FlaggedSheet(container: AppContainer, dictionaryId: String, onClose: () -> Unit) {
    val vm: FlaggedViewModel = viewModel(
        key = "flagged-sheet-$dictionaryId",
        factory = viewModelFactory { initializer { FlaggedViewModel(container, onlyDictionaryId = dictionaryId) } },
    )
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { vm.clearNotice() }
    ModalBottomSheet(onDismissRequest = onClose, sheetState = sheetState, containerColor = AppTheme.colors.desk) {
        FlaggedContent(
            vm, openReceipt = null,
            close = { scope.launch { sheetState.hide() }.invokeOnCompletion { onClose() } },
            modifier = Modifier.fillMaxHeight(),
        )
    }
}
