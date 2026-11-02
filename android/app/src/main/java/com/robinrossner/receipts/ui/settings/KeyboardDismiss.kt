package com.robinrossner.receipts.ui.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController

/** `scrollDismissesKeyboard(.interactively)` of the iPhone: dragging the content hides the keyboard and drops the focus. */
@Composable
fun Modifier.dismissKeyboardOnDrag(): Modifier {
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val connection = remember(focus, keyboard) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.UserInput && available.y != 0f) {
                    keyboard?.hide()
                    focus.clearFocus()
                }
                return Offset.Zero
            }
        }
    }
    return this.nestedScroll(connection)
}
