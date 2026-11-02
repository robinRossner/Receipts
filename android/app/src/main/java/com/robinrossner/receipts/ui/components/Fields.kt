package com.robinrossner.receipts.ui.components

import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme

/**
 * The text field of the iPhone app: `field` box, 6dp corners, 1dp `rule` border (`ink` while focused), 10dp side padding, at least 40dp high.
 * [boxed] = false gives bare text (the store name in the receipt header). An unspecified colour in [textStyle] becomes `ink`.
 */
@Composable
fun AppTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    textStyle: TextStyle = AppTheme.body(14),
    placeholder: String? = null,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    singleLine: Boolean = true,
    textAlign: TextAlign = TextAlign.Start,
    boxed: Boolean = true,
    interactionSource: MutableInteractionSource? = null,
) {
    val c = AppTheme.colors
    var focused by remember { mutableStateOf(false) }
    val style = textStyle.copy(color = if (textStyle.color == androidx.compose.ui.graphics.Color.Unspecified) c.ink else textStyle.color, textAlign = textAlign)
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.onFocusChanged { focused = it.isFocused },
        textStyle = style,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        singleLine = singleLine,
        visualTransformation = visualTransformation,
        interactionSource = interactionSource,
        cursorBrush = SolidColor(c.ink),
        decorationBox = { inner ->
            Box(
                (if (boxed) Modifier.fieldBox(focused).heightIn(min = 40.dp).padding(horizontal = 10.dp) else Modifier),
                contentAlignment = if (boxed) Alignment.CenterStart else Alignment.TopStart,
            ) {
                if (value.isEmpty() && placeholder != null) Text(placeholder, style = style.copy(color = c.inkSoft), maxLines = 1)
                inner()
            }
        },
    )
}
