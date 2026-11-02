package com.robinrossner.receipts.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme

/** A boxed group of picker rows (`field` box, 6dp corners, 1dp border, 10dp side padding). Put a [RuleDivider] between the rows. */
@Composable
fun PickerGroup(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().fieldBox().padding(horizontal = 10.dp), content = content)
}

/**
 * One row of the cascading category picker: [title] left, the current [value] right with an up/down mark, a menu of [options] on tap.
 * Its test tag defaults to [title] (`Category`, `Subcategory`, `Item group`), which is also its accessibility label.
 */
@Composable
fun MenuPickerRow(
    title: String,
    value: String,
    options: List<String>,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
    minHeight: Dp = 40.dp,
    testTag: String? = null,
) {
    val c = AppTheme.colors
    var open by remember { mutableStateOf(false) }
    Box(modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth().heightIn(min = minHeight)
                .testTag(testTag ?: title)
                .clickable(role = Role.Button) { open = true }
                .semantics(mergeDescendants = true) { contentDescription = title; stateDescription = value },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, style = AppTheme.body(13, color = c.inkSoft), maxLines = 1)
            Spacer(Modifier.width(8.dp))
            // Fills the rest of the row and aligns to its end, so the value sits against the up/down mark at the right edge.
            Text(
                value.ifEmpty { "—" }, style = AppTheme.body(14, color = c.ink), textAlign = TextAlign.End,
                maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(6.dp))
            Icon(Icons.Filled.UnfoldMore, null, Modifier.size(14.dp), tint = c.inkSoft)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = c.paper) {
            options.forEach { option ->
                val selected = option == value
                DropdownMenuItem(
                    text = { Text(option, style = AppTheme.body(14, if (selected) FontWeight.SemiBold else FontWeight.Normal, c.ink)) },
                    leadingIcon = { if (selected) Icon(Icons.Filled.Check, null, Modifier.size(16.dp), tint = c.ink) else Spacer(Modifier.size(16.dp)) },
                    onClick = { open = false; onSelect(option) },
                )
            }
        }
    }
}
