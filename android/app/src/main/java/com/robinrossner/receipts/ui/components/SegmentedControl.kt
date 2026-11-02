package com.robinrossner.receipts.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.ui.theme.AppTheme

/**
 * The iPhone segmented picker: a `segmentTrack` bar, 36dp high, with the selected segment lifted on `segmentThumb`.
 * Each segment is a button named by its label (UI tests tap by that name), with the `selected` state. [testTags] are per segment.
 */
@Composable
fun SegmentedControl(
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    testTags: List<String>? = null,
) {
    val c = AppTheme.colors
    Row(
        modifier.fillMaxWidth().height(36.dp).background(c.segmentTrack, RoundedCornerShape(8.dp)).padding(2.dp),
    ) {
        options.forEachIndexed { i, label ->
            val isSelected = i == selectedIndex
            val thumb = RoundedCornerShape(6.dp)
            Box(
                Modifier
                    .weight(1f).fillMaxHeight()
                    .let { if (testTags != null) it.testTag(testTags[i]) else it }
                    .let { if (isSelected) it.background(c.segmentThumb, thumb).border(1.dp, c.rule, thumb) else it }
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) { onSelect(i) }
                    .semantics(mergeDescendants = true) { role = Role.Button; selected = isSelected; contentDescription = label },
                contentAlignment = Alignment.Center,
            ) {
                Text(label, style = AppTheme.body(13, if (isSelected) FontWeight.Medium else FontWeight.Normal, c.ink), maxLines = 1)
            }
        }
    }
}
