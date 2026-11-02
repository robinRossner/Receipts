package com.robinrossner.receipts.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme
import com.robinrossner.receipts.ui.theme.EaseOut
import com.robinrossner.receipts.ui.theme.Motion
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The one-line "… deleted. Undo" message (`SnackCenter`): one at a time, gone after 5 seconds. Created once in `RootScreen`. */
class SnackCenter(private val scope: CoroutineScope) {
    data class Snack(val id: Long, val text: String, val undo: suspend () -> Unit)

    var current by mutableStateOf<Snack?>(null)
        private set
    private var nextId = 0L
    private var timer: Job? = null

    /** Replaces any current snack; hides itself after exactly 5 seconds if still current. */
    fun show(text: String, undo: suspend () -> Unit) {
        timer?.cancel()
        val snack = Snack(++nextId, text, undo)
        current = snack
        timer = scope.launch {
            delay(5_000)
            if (current?.id == snack.id) current = null
        }
    }

    /** Hides the snack at once, then runs its undo. */
    fun performUndo() {
        val snack = current ?: return
        timer?.cancel()
        current = null
        scope.launch { snack.undo() }
    }
}

val LocalSnackCenter = staticCompositionLocalOf<SnackCenter> { error("no SnackCenter") }

/**
 * The dark undo bar (`Theme.SnackbarBar`). Pass `SnackCenter.current` and `SnackCenter::performUndo`; the caller adds
 * `Modifier.padding(start = 14.dp, end = 14.dp, bottom = 8.dp)`. Not an M3 `SnackbarHost`.
 */
@Composable
fun SnackbarBar(snack: SnackCenter.Snack?, onUndo: () -> Unit, modifier: Modifier = Modifier) {
    val c = AppTheme.colors
    // Keep the last text on screen while the bar slides out.
    var shown by remember { mutableStateOf(snack) }
    if (snack != null) shown = snack
    AnimatedVisibility(
        visible = snack != null,
        modifier = modifier,
        enter = slideInVertically(tween(Motion.MEDIUM, easing = EaseOut)) { it } + fadeIn(tween(Motion.MEDIUM, easing = EaseOut)),
        exit = slideOutVertically(tween(Motion.MEDIUM, easing = EaseOut)) { it } + fadeOut(tween(Motion.MEDIUM, easing = EaseOut)),
    ) {
        val shape = RoundedCornerShape(10.dp)
        Row(
            Modifier.fillMaxWidth()
                .shadow(6.dp, shape, ambientColor = Color.Black.copy(alpha = 0.2f), spotColor = Color.Black.copy(alpha = 0.2f))
                .background(c.ink, shape)
                .padding(start = 14.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(shown?.text.orEmpty(), Modifier.weight(1f), style = AppTheme.body(14, color = c.onInk), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Box(
                Modifier.testTag("undoButton").defaultMinSize(minWidth = 44.dp, minHeight = 44.dp)
                    .clickable(role = Role.Button, onClick = onUndo).padding(horizontal = 6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("Undo", style = AppTheme.body(14, FontWeight.SemiBold, c.onInk).copy(textDecoration = TextDecoration.Underline))
            }
        }
    }
}

/** The red bar for store failures (`ReceiptStore.lastError`): set with [show], cleared by the user with [dismiss]. */
class ErrorCenter {
    var current by mutableStateOf<String?>(null)
        private set

    fun show(message: String) { current = message }
    fun dismiss() { current = null }
}

val LocalErrorCenter = staticCompositionLocalOf<ErrorCenter> { error("no ErrorCenter") }
