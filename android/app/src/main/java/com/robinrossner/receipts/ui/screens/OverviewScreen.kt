package com.robinrossner.receipts.ui.screens

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.LabelOff
import androidx.compose.material.icons.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.robinrossner.receipts.data.CategoryStat
import com.robinrossner.receipts.data.OverviewCursor
import com.robinrossner.receipts.data.PurchaseRow
import com.robinrossner.receipts.data.SpendDelta
import com.robinrossner.receipts.data.StatsCalc
import com.robinrossner.receipts.data.StoreTotal
import com.robinrossner.receipts.ui.OverviewUi
import com.robinrossner.receipts.ui.OverviewViewModel
import com.robinrossner.receipts.ui.RangeMode
import com.robinrossner.receipts.ui.components.AppTopBar
import com.robinrossner.receipts.ui.components.OutlineButton
import com.robinrossner.receipts.ui.components.RuleDivider
import com.robinrossner.receipts.ui.components.SectionLabel
import com.robinrossner.receipts.ui.components.SegmentedControl
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.components.paperCard
import com.robinrossner.receipts.ui.overview.ChartLegend
import com.robinrossner.receipts.ui.overview.MonthlyChart
import com.robinrossner.receipts.ui.overview.OverviewLogic
import com.robinrossner.receipts.ui.overview.PriceHistory
import com.robinrossner.receipts.ui.overview.seriesColors
import com.robinrossner.receipts.ui.theme.AppTheme
import com.robinrossner.receipts.ui.theme.EaseInOut
import com.robinrossner.receipts.ui.theme.EaseOut
import com.robinrossner.receipts.ui.theme.Motion
import com.robinrossner.receipts.ui.theme.appDatePickerColors
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.max

/** Range, total, flagged items, spending charts and the expandable category > subcategory > item group tree with a purchase drill-down. */
@Composable
fun OverviewScreen(vm: OverviewViewModel, onOpenReceipt: (uuid: String, itemDictionaryId: String?) -> Unit, onOpenFlagged: () -> Unit) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val flagged by vm.flaggedItemCount.collectAsStateWithLifecycle()
    Column(Modifier.fillMaxSize().background(AppTheme.colors.desk)) {
        AppTopBar("Overview", titleSize = 20f)
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            RangeHeader(vm, ui)
            TotalBlock(ui)
            if (flagged > 0) FlaggedRow(flagged, onOpenFlagged)
            if (ui.monthly.isNotEmpty()) MonthlyCard(ui)
            if (ui.stores.isNotEmpty()) StoresCard(ui.stores)
            val summary = ui.summary
            if (summary != null) {
                if (summary.categories.isNotEmpty()) CategoryTree(vm, ui, summary.categories, onOpenReceipt)
                else EmptyState(ui.monthly.isEmpty())
            }
        }
    }
}

// ---------------------------------------------------------------- range header

@Composable
private fun RangeHeader(vm: OverviewViewModel, ui: OverviewUi) {
    val colors = AppTheme.colors
    var pickStart by remember { mutableStateOf(false) }
    var pickEnd by remember { mutableStateOf(false) }
    var turns by remember { mutableIntStateOf(0) }
    val rotation by animateFloatAsState(turns * 360f, tween(Motion.REFRESH, easing = EaseInOut), label = "refresh")
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SegmentedControl(
            RangeMode.entries.map { it.label }, RangeMode.entries.indexOf(ui.mode), { vm.setMode(RangeMode.entries[it]) }, Modifier.fillMaxWidth(),
            testTags = RangeMode.entries.map { "range_${it.name}" },
        )
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            when (ui.mode) {
                RangeMode.MONTH, RangeMode.YEAR -> {
                    NavButton(Icons.Filled.KeyboardArrowLeft, "Previous") { vm.move(-1) }
                    RangeTitle(ui.rangeLabel, Modifier.weight(1f).testTag("rangeLabel"))
                    NavButton(Icons.Filled.KeyboardArrowRight, "Next", enabled = !OverviewCursor.isLatest(ui.cursor, ui.mode == RangeMode.YEAR)) { vm.move(1) }
                }
                RangeMode.CUSTOM -> {
                    DatePill(ui.customStart, "From") { pickStart = true }
                    Text("–", style = AppTheme.body(14, color = colors.label))
                    DatePill(ui.customEnd, "To") { pickEnd = true }
                    Spacer(Modifier.weight(1f))
                }
                RangeMode.ALL -> RangeTitle("All time", Modifier.weight(1f).testTag("rangeLabel"))
            }
            NavButton(Icons.Outlined.Refresh, "Refresh", iconModifier = Modifier.rotate(rotation)) { turns++; vm.reload() }
        }
    }
    if (pickStart) DatePick(ui.customStart, { pickStart = false }) { vm.setCustomStart(it); pickStart = false }
    if (pickEnd) DatePick(ui.customEnd, { pickEnd = false }) { vm.setCustomEnd(it); pickEnd = false }
}

@Composable
private fun RangeTitle(text: String, modifier: Modifier) {
    Text(text, modifier, style = AppTheme.display(19, AppTheme.colors.ink), textAlign = TextAlign.Center, maxLines = 1)
}

/** 40dp square on `paper` inside a 44dp tap target, `Theme.NavButton`. */
@Composable
private fun NavButton(icon: ImageVector, description: String, enabled: Boolean = true, iconModifier: Modifier = Modifier, onClick: () -> Unit) {
    val c = AppTheme.colors
    val shape = RoundedCornerShape(8.dp)
    Box(
        Modifier.size(44.dp).alpha(if (enabled) 1f else 0.3f).padding(2.dp).clip(shape).background(c.paper).border(1.dp, c.rule, shape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, iconModifier.size(15.dp), tint = c.ink) }
}

@Composable
private fun DatePill(date: LocalDate, description: String, onClick: () -> Unit) {
    val c = AppTheme.colors
    val shape = RoundedCornerShape(8.dp)
    Box(
        Modifier.heightIn(min = 44.dp).clip(shape).background(c.field).border(1.dp, c.rule, shape)
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 12.dp)
            .semantics(mergeDescendants = true) { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Text(date.toString(), style = AppTheme.mono(14, FontWeight.Medium, c.ink)) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DatePick(initial: LocalDate, onDismiss: () -> Unit, onPick: (LocalDate) -> Unit) {
    val c = AppTheme.colors
    val state = rememberDatePickerState(initialSelectedDateMillis = initial.atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli())
    val colors = appDatePickerColors()
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = { state.selectedDateMillis?.let { onPick(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()) } }) {
                Text("OK", color = c.ink)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = c.ink) } },
        colors = colors,
    ) { DatePicker(state, colors = colors) }
}

// ---------------------------------------------------------------- total and flagged

/** Text that shrinks (down to [minScale]) instead of wrapping or clipping. */
@Composable
private fun ShrinkText(text: String, style: TextStyle, modifier: Modifier = Modifier, minScale: Float = 0.6f, textAlign: TextAlign? = null) {
    var scale by remember(text) { mutableFloatStateOf(1f) }
    Text(
        text, modifier, style = style.copy(fontSize = style.fontSize * scale), maxLines = 1, softWrap = false, overflow = TextOverflow.Clip, textAlign = textAlign,
        onTextLayout = { if (it.didOverflowWidth && scale > minScale) scale = max(minScale, scale * 0.9f) },
    )
}

@Composable
private fun trendColor(trend: SpendDelta.Trend): Color {
    val c = AppTheme.colors
    return when (trend) { SpendDelta.Trend.UP -> c.red; SpendDelta.Trend.DOWN -> c.greenText; SpendDelta.Trend.FLAT -> c.label }
}

@Composable
private fun TotalBlock(ui: OverviewUi) {
    val c = AppTheme.colors
    val total = ui.summary?.total
    val delta = if (total != null && total > 0) SpendDelta.make(total, ui.previous?.total, ui.previous != null, ui.previousLabel) else null
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text("Total:", style = AppTheme.body(13, FontWeight.Medium, c.label))
        ShrinkText(
            if (total != null && total > 0) fmtMoney(total) else "—", AppTheme.mono(36, FontWeight.SemiBold, c.ink),
            Modifier.fillMaxWidth().testTag("overviewTotal"), textAlign = TextAlign.Center,
        )
        if (delta != null) Text(delta.text, style = AppTheme.body(13, FontWeight.Medium, trendColor(delta.trend)))
    }
}

@Composable
private fun FlaggedRow(count: Int, onClick: () -> Unit) {
    val c = AppTheme.colors
    val shape = RoundedCornerShape(8.dp)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(shape).background(c.paper).border(1.dp, c.rule, shape)
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 12.dp).testTag("flaggedItemsRow"),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Outlined.LabelOff, null, Modifier.size(14.dp), tint = c.inkSoft)
        Text("Items without a category ($count)", Modifier.weight(1f), style = AppTheme.body(14, color = c.ink))
        Icon(Icons.Filled.KeyboardArrowRight, null, Modifier.size(11.dp), tint = c.inkSoft)
    }
}

// ---------------------------------------------------------------- charts

@Composable
private fun MonthlyCard(ui: OverviewUi) {
    val series = remember(ui.monthly) { StatsCalc.seriesNames(ui.monthly) }
    val colors = seriesColors(series)
    Column(Modifier.fillMaxWidth().paperCard(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionLabel("Spending by month")
        MonthlyChart(ui.monthly, series, colors, ui.highlightMonth)
        ChartLegend(series, colors)
    }
}

@Composable
private fun StoresCard(stores: List<StoreTotal>) {
    val c = AppTheme.colors
    val peak = stores.maxOf { it.total }
    Column(Modifier.fillMaxWidth().paperCard(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionLabel("By store")
        Column(Modifier.fillMaxWidth().testTag("storeChart"), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            stores.forEach { s ->
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(s.store, Modifier.weight(1f), style = AppTheme.body(13.5f, color = c.ink), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Spacer(Modifier.width(8.dp))
                        Text(fmtMoney(s.total), style = AppTheme.mono(13, FontWeight.Medium, c.ink))
                    }
                    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxWidth().height(6.dp)) {
                        val w = OverviewLogic.storeBarWidth(s.total, peak, maxWidth.value, 3f).dp
                        Box(Modifier.width(w).height(6.dp).background(if (s.store == StatsCalc.OTHER) c.seriesOther else c.series[2], RoundedCornerShape(2.dp)))
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- tree

@Composable
private fun EmptyState(noMonthly: Boolean) {
    val c = AppTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(top = if (noMonthly) 50.dp else 16.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Outlined.BarChart, null, Modifier.size(40.dp), tint = c.label)
        Text("No spending in this period.", style = AppTheme.body(15, color = c.label))
    }
}

@Composable
private fun CategoryTree(vm: OverviewViewModel, ui: OverviewUi, categories: List<CategoryStat>, onOpenReceipt: (String, String?) -> Unit) {
    val hasComparison = ui.previous != null
    fun delta(current: Double, previous: Double?) = SpendDelta.make(current, previous, hasComparison, ui.previousLabel)
    Column(Modifier.fillMaxWidth().testTag("categoryTree").paperCard(padding = 4.dp)) {
        categories.forEachIndexed { index, cat ->
            val catKey = OverviewViewModel.key(cat.category)
            val prevCat = ui.previous?.categories?.firstOrNull { it.category == cat.category }
            TreeRow(cat.category, cat.total, 0, catKey in ui.openNodes, delta(cat.total, prevCat?.total)) { vm.toggle(catKey) }
            if (catKey in ui.openNodes) cat.subcategories.forEach { sub ->
                val subKey = OverviewViewModel.key(cat.category, sub.subcategory)
                val prevSub = prevCat?.subcategories?.firstOrNull { it.subcategory == sub.subcategory }
                TreeRow(sub.subcategory, sub.total, 1, subKey in ui.openNodes, delta(sub.total, prevSub?.total)) { vm.toggle(subKey) }
                if (subKey in ui.openNodes) sub.itemGroups.forEach { group ->
                    val groupKey = OverviewViewModel.key(cat.category, sub.subcategory, group.itemGroup)
                    TreeRow(group.itemGroup, group.total, 2, groupKey in ui.openNodes, null) { vm.toggle(groupKey) }
                    if (groupKey in ui.openNodes) Drilldown(ui, groupKey, onOpenReceipt)
                }
            }
            if (index < categories.size - 1) RuleDivider()
        }
    }
}

@Composable
private fun TreeRow(title: String, total: Double, level: Int, open: Boolean, delta: SpendDelta?, onClick: () -> Unit) {
    val c = AppTheme.colors
    val chevron by animateFloatAsState(if (open) 90f else 0f, tween(Motion.FAST, easing = EaseOut), label = "chevron")
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(role = Role.Button, onClick = onClick)
            .padding(start = (6 + 16 * level).dp, end = 8.dp, top = 9.dp, bottom = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.size(width = 14.dp, height = 20.dp), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.KeyboardArrowRight, null, Modifier.size(11.dp).rotate(chevron), tint = c.inkSoft)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Row(Modifier.fillMaxWidth()) {
                Text(
                    title, Modifier.weight(1f).alignByBaseline(),
                    style = AppTheme.body(if (level == 0) 15.5f else if (level == 1) 14.5f else 14f, if (level == 0) FontWeight.SemiBold else FontWeight.Normal, c.ink),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    fmtMoney(total), Modifier.alignByBaseline(),
                    style = AppTheme.mono(if (level == 0) 15 else 14, if (level == 0) FontWeight.SemiBold else FontWeight.Normal, c.ink),
                )
            }
            if (delta != null && level < 2) Text(delta.text, style = AppTheme.body(12, color = trendColor(delta.trend)))
        }
    }
}

// ---------------------------------------------------------------- drill-down

@Composable
private fun Drilldown(ui: OverviewUi, key: String, onOpenReceipt: (String, String?) -> Unit) {
    val c = AppTheme.colors
    val detail = ui.groupDetails[key]
    Column(Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (detail == null) {
            Text("Loading…", Modifier.padding(vertical = 6.dp), style = AppTheme.body(14, color = c.inkSoft))
        } else {
            if (detail.history.size >= 2) PriceHistory(detail.history)
            if (detail.purchases.isEmpty()) Text("No purchases found.", Modifier.padding(vertical = 6.dp), style = AppTheme.body(14, color = c.inkSoft))
            Column(Modifier.fillMaxWidth()) {
                detail.purchases.forEachIndexed { i, p ->
                    PurchaseRowView(p) { onOpenReceipt(p.receiptId, p.itemDictionaryId) }
                    if (i < detail.purchases.size - 1) RuleDivider(alpha = 0.6f)
                }
            }
        }
    }
}

@Composable
private fun PurchaseRowView(p: PurchaseRow, onEdit: () -> Unit) {
    val c = AppTheme.colors
    Row(Modifier.fillMaxWidth().padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(p.translationEn ?: p.nameDe ?: "", style = AppTheme.body(14, color = c.ink), maxLines = 1, overflow = TextOverflow.Ellipsis)
            ShrinkText("${p.date ?: ""} · ${p.store ?: ""}", AppTheme.mono(11, color = c.inkSoft), minScale = 0.8f)
        }
        Spacer(Modifier.width(4.dp))
        Text(fmtMoney(p.totalPrice), style = AppTheme.mono(13.5f, FontWeight.Medium, c.ink))
        OutlineButton("Edit", onEdit)
    }
}
