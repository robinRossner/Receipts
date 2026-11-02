package com.robinrossner.receipts.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.robinrossner.receipts.data.CategoryStat
import com.robinrossner.receipts.data.MonthCategoryTotal
import com.robinrossner.receipts.data.PricePoint
import com.robinrossner.receipts.data.StatsCalc
import com.robinrossner.receipts.data.StatsSummary
import com.robinrossner.receipts.data.StoreTotal
import com.robinrossner.receipts.ui.OverviewUi
import com.robinrossner.receipts.ui.OverviewViewModel
import com.robinrossner.receipts.ui.RangeMode
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.theme.AppTheme
import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneOffset
import java.time.format.TextStyle
import java.util.Locale

/** Month navigator, running total, spending charts and the expandable category > subcategory > item group tree with a purchase drill-down. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OverviewScreen(vm: OverviewViewModel, onOpenReceipt: (uuid: String, itemDictionaryId: String?) -> Unit, onOpenFlagged: () -> Unit) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val colors = AppTheme.colors
    Scaffold(
        containerColor = colors.desk,
        contentWindowInsets = androidx.compose.foundation.layout.WindowInsets(0),
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Overview", style = AppTheme.display(20.sp, colors.ink)) },
                windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = colors.paper),
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            RangeHeader(vm, ui)
            Text("Total: ${fmtMoney(ui.summary?.total)}", Modifier.fillMaxWidth().testTag("overviewTotal"), style = AppTheme.mono(22, color = colors.ink), textAlign = TextAlign.Center)
            SpendingCharts(ui.monthly, ui.stores, ui.highlightMonth, ui.mode, ui.cursor)
            CategoryTree(vm, ui) { onOpenReceipt(it, null) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RangeHeader(vm: OverviewViewModel, ui: OverviewUi) {
    val colors = AppTheme.colors
    var pickStart by remember { mutableStateOf(false) }
    var pickEnd by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            RangeMode.entries.forEachIndexed { i, m ->
                SegmentedButton(
                    selected = ui.mode == m, onClick = { vm.setMode(m) }, shape = SegmentedButtonDefaults.itemShape(i, RangeMode.entries.size),
                    modifier = Modifier.testTag("range_${m.name}"),
                    colors = SegmentedButtonDefaults.colors(
                        activeContainerColor = colors.ink, activeContentColor = colors.onInk, inactiveContainerColor = colors.paper,
                        inactiveContentColor = colors.ink, activeBorderColor = colors.ink, inactiveBorderColor = colors.rule,
                    ),
                    icon = {},
                ) { Text(m.label, style = AppTheme.body(12), maxLines = 1) }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            when (ui.mode) {
                RangeMode.MONTH, RangeMode.YEAR -> {
                    NavButton("‹", "Previous") { vm.move(-1) }
                    Text(ui.rangeLabel, Modifier.width(170.dp).testTag("rangeLabel"), style = AppTheme.display(17.sp, colors.ink), textAlign = TextAlign.Center)
                    NavButton("›", "Next") { vm.move(1) }
                }
                RangeMode.CUSTOM -> {
                    TextButton(onClick = { pickStart = true }) { Text("From ${ui.customStart}", color = colors.ink, style = AppTheme.mono(12)) }
                    TextButton(onClick = { pickEnd = true }) { Text("To ${ui.customEnd}", color = colors.ink, style = AppTheme.mono(12)) }
                }
                RangeMode.ALL -> Text("All time", style = AppTheme.display(17.sp, colors.ink))
            }
            NavButton("⟳", "Reload") { vm.reload() }
        }
    }
    if (pickStart) DatePick(ui.customStart, { pickStart = false }) { vm.setCustomStart(it); pickStart = false }
    if (pickEnd) DatePick(ui.customEnd, { pickEnd = false }) { vm.setCustomEnd(it); pickEnd = false }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DatePick(initial: LocalDate, onDismiss: () -> Unit, onPick: (LocalDate) -> Unit) {
    val state = rememberDatePickerState(initialSelectedDateMillis = initial.atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli())
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = { state.selectedDateMillis?.let { onPick(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()) } }) { Text("OK") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    ) { DatePicker(state) }
}

@Composable
private fun NavButton(symbol: String, description: String, onClick: () -> Unit) {
    val colors = AppTheme.colors
    Box(
        Modifier.size(34.dp).clip(RoundedCornerShape(4.dp)).background(colors.paper).border(1.dp, colors.rule, RoundedCornerShape(4.dp))
            .clickable(onClickLabel = description, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(symbol, style = AppTheme.body(15, color = colors.ink)) }
}

// ---------------------------------------------------------------- charts

@Composable
private fun SpendingCharts(monthly: List<MonthCategoryTotal>, stores: List<StoreTotal>, highlightMonth: String?, mode: RangeMode, cursor: LocalDate) {
    if (monthly.isEmpty() && stores.isEmpty()) return
    val series = StatsCalc.seriesNames(monthly)
    val colors = series.mapIndexed { i, n -> if (n == StatsCalc.OTHER) AppTheme.colors.seriesOther else AppTheme.colors.series[i % AppTheme.colors.series.size] }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        ChartCard("Spending by month") {
            StackedBars(monthly, series, colors, highlightMonth, if (mode == RangeMode.MONTH) cursor else null)
            Legend(series, colors)
        }
        ChartCard("By store") { StoreBars(stores) }
    }
}

@Composable
private fun ChartCard(title: String, content: @Composable () -> Unit) {
    val c = AppTheme.colors
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp)).background(c.paper).border(1.dp, c.rule, RoundedCornerShape(4.dp)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(title.uppercase(), style = AppTheme.body(11, FontWeight.Medium, c.inkSoft))
        content()
    }
}

/** Months from the first to the last with data (the 12 months up to the selected one in month view), gaps included. */
private fun monthAxis(monthly: List<MonthCategoryTotal>, endMonth: LocalDate?): List<String> {
    val months = monthly.mapNotNull { runCatching { YearMonth.parse(it.month) }.getOrNull() }
    if (endMonth != null) {
        val end = YearMonth.from(endMonth)
        return (11 downTo 0).map { end.minusMonths(it.toLong()).toString() }
    }
    val first = months.minOrNull() ?: return emptyList()
    val last = months.max()
    return generateSequence(first) { if (it < last) it.plusMonths(1) else null }.map { it.toString() }.toList()
}

@Composable
private fun StackedBars(monthly: List<MonthCategoryTotal>, series: List<String>, seriesColors: List<Color>, highlight: String?, endMonth: LocalDate?) {
    val c = AppTheme.colors
    val measurer = rememberTextMeasurer()
    val axis = monthAxis(monthly, endMonth)
    val bars = StatsCalc.stackedBars(monthly, series).toMap()
    val maxTotal = axis.maxOfOrNull { m -> bars[m]?.sumOf { it.second } ?: 0.0 } ?: 0.0
    val top = niceCeil(maxTotal)
    val labelStyle = AppTheme.body(10, color = c.inkSoft)
    Canvas(Modifier.fillMaxWidth().height(220.dp).testTag("monthChart")) {
        val leftPad = 44.dp.toPx()
        val bottomPad = 20.dp.toPx()
        val plotW = size.width - leftPad
        val plotH = size.height - bottomPad
        // gridlines + € labels
        for (i in 0..4) {
            val v = top * i / 4
            val y = plotH - (plotH * i / 4f)
            drawLine(c.rule, Offset(leftPad, y), Offset(size.width, y), strokeWidth = 1f)
            val label = measurer.measure("€${v.toInt()}", labelStyle)
            drawText(label, topLeft = Offset(leftPad - label.size.width - 6.dp.toPx(), y - label.size.height / 2f))
        }
        if (axis.isEmpty() || top <= 0) return@Canvas
        val slot = plotW / axis.size
        val barW = slot * 0.62f
        val every = ((axis.size + 11) / 12).coerceAtLeast(1)
        axis.forEachIndexed { i, month ->
            val x = leftPad + slot * i + (slot - barW) / 2
            val dim = highlight != null && month != highlight
            var y = plotH
            bars[month]?.forEach { (name, value) ->
                val h = (value / top * plotH).toFloat()
                val color = seriesColors[series.indexOf(name).coerceAtLeast(0)].copy(alpha = if (dim) 0.45f else 1f)
                drawRect(color, Offset(x, y - h), Size(barW, h))
                y -= h
            }
            if (i % every == 0) {
                val ym = runCatching { YearMonth.parse(month) }.getOrNull()
                val text = ym?.month?.getDisplayName(TextStyle.SHORT, Locale.getDefault()) ?: month
                val label = measurer.measure(text, labelStyle)
                drawText(label, topLeft = Offset(x + barW / 2 - label.size.width / 2f, plotH + 4.dp.toPx()))
            }
        }
    }
}

private fun niceCeil(v: Double): Double {
    if (v <= 0) return 0.0
    val magnitude = Math.pow(10.0, Math.floor(Math.log10(v)))
    val n = v / magnitude
    val step = when { n <= 1 -> 1.0; n <= 2 -> 2.0; n <= 2.5 -> 2.5; n <= 5 -> 5.0; else -> 10.0 }
    return step * magnitude
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Legend(names: List<String>, colors: List<Color>) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        names.forEachIndexed { i, n ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Box(Modifier.size(8.dp).background(colors[i], androidx.compose.foundation.shape.CircleShape))
                Text(n, style = AppTheme.body(11, color = AppTheme.colors.inkSoft))
            }
        }
    }
}

@Composable
private fun StoreBars(stores: List<StoreTotal>) {
    val c = AppTheme.colors
    val max = stores.maxOfOrNull { it.total } ?: 0.0
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.testTag("storeChart")) {
        stores.forEach { s ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(s.store, Modifier.width(84.dp), style = AppTheme.body(12, color = c.ink), maxLines = 1)
                Box(Modifier.weight(1f).height(16.dp)) {
                    val frac = if (max > 0) (s.total / max).toFloat().coerceIn(0.02f, 1f) else 0f
                    Box(Modifier.fillMaxWidth(frac).height(16.dp).background(c.ink))
                }
                Text(fmtMoney(s.total), Modifier.width(64.dp), style = AppTheme.mono(10, color = c.inkSoft), textAlign = TextAlign.End)
            }
        }
    }
}

/** Unit price over time, one line per item, in an item-group drill-down. */
@Composable
private fun PriceHistoryChart(points: List<PricePoint>) {
    val c = AppTheme.colors
    val measurer = rememberTextMeasurer()
    val names = points.map { it.item }.distinct().sorted()
    val colors = names.indices.map { c.series[it % c.series.size] }
    val minDate = points.minOf { it.date }.toEpochDay()
    val maxDate = points.maxOf { it.date }.toEpochDay().coerceAtLeast(minDate + 1)
    val maxPrice = points.maxOf { it.unitPrice }
    val top = niceCeil(maxPrice)
    val labelStyle = AppTheme.body(9, color = c.inkSoft)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(bottom = 6.dp)) {
        Text("PRICE HISTORY (unit price, all time)", style = AppTheme.body(10, FontWeight.Medium, c.inkSoft))
        Canvas(Modifier.fillMaxWidth().height(140.dp).testTag("priceChart")) {
            val leftPad = 44.dp.toPx(); val bottomPad = 16.dp.toPx()
            val plotW = size.width - leftPad - 6.dp.toPx(); val plotH = size.height - bottomPad
            for (i in 0..3) {
                val y = plotH - plotH * i / 3f
                drawLine(c.rule, Offset(leftPad, y), Offset(size.width, y), 1f)
                val l = measurer.measure(String.format(Locale.US, "€%.2f", top * i / 3), labelStyle)
                drawText(l, topLeft = Offset(leftPad - l.size.width - 4.dp.toPx(), y - l.size.height / 2f))
            }
            fun pos(p: PricePoint) = Offset(leftPad + plotW * ((p.date.toEpochDay() - minDate).toFloat() / (maxDate - minDate)), (plotH - plotH * (p.unitPrice / top)).toFloat())
            names.forEachIndexed { i, name ->
                val pts = points.filter { it.item == name }.sortedBy { it.date }
                val path = Path()
                pts.forEachIndexed { k, p -> val o = pos(p); if (k == 0) path.moveTo(o.x, o.y) else path.lineTo(o.x, o.y) }
                drawPath(path, colors[i], style = Stroke(width = 2.dp.toPx()))
                pts.forEach { drawCircle(colors[i], 3.dp.toPx(), pos(it)) }
            }
            val first = measurer.measure(LocalDate.ofEpochDay(minDate).toString(), labelStyle)
            val last = measurer.measure(LocalDate.ofEpochDay(maxDate).toString(), labelStyle)
            drawText(first, topLeft = Offset(leftPad, plotH + 3.dp.toPx()))
            drawText(last, topLeft = Offset(size.width - last.size.width, plotH + 3.dp.toPx()))
        }
        Legend(names, colors)
    }
}

// ---------------------------------------------------------------- tree

@Composable
private fun CategoryTree(vm: OverviewViewModel, ui: OverviewUi, onOpenReceipt: (String) -> Unit) {
    val summary = ui.summary
    val colors = AppTheme.colors
    if (summary == null || summary.categories.isEmpty()) {
        Text("No spending in this period.", style = AppTheme.body(13, color = colors.inkSoft))
        return
    }
    val hasPrevious = ui.previous != null
    Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.testTag("categoryTree")) {
        summary.categories.forEach { cat ->
            val catKey = OverviewViewModel.key(cat.category)
            val open = catKey in ui.openNodes
            val prevCat = ui.previous?.categories?.firstOrNull { it.category == cat.category }
            TreeRow(cat.category, cat.total, 0, open, prevCat?.total, hasPrevious, ui.previousLabel) { vm.toggle(catKey) }
            if (open) cat.subcategories.forEach { sub ->
                val subKey = OverviewViewModel.key(cat.category, sub.subcategory)
                val subOpen = subKey in ui.openNodes
                val prevSub = prevCat?.subcategories?.firstOrNull { it.subcategory == sub.subcategory }
                TreeRow(sub.subcategory, sub.total, 1, subOpen, prevSub?.total, hasPrevious, ui.previousLabel) { vm.toggle(subKey) }
                if (subOpen) sub.itemGroups.forEach { ig ->
                    val key = OverviewViewModel.key(cat.category, sub.subcategory, ig.itemGroup)
                    val groupOpen = key in ui.openNodes
                    TreeRow(ig.itemGroup, ig.total, 2, groupOpen, null, false, ui.previousLabel) { vm.toggle(key) }
                    if (groupOpen) Purchases(ui, key, onOpenReceipt)
                }
            }
        }
    }
}

@Composable
private fun TreeRow(label: String, total: Double, depth: Int, open: Boolean, previous: Double?, hasPrevious: Boolean, previousLabel: String, onClick: () -> Unit) {
    val c = AppTheme.colors
    val bg = c.paper
    val delta = if (depth < 2) StatsCalc.deltaText(total, previous, hasPrevious, previousLabel) else null
    val deltaColor = when {
        previous == null || previous <= 0 -> c.inkSoft
        total > previous -> c.red
        total < previous -> c.green
        else -> c.inkSoft
    }
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp)).background(bg).border(1.dp, c.rule, RoundedCornerShape(4.dp))
            .clickable(onClick = onClick).padding(start = 12.dp + 20.dp * depth, end = 12.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(if (open) "▾" else "▸", Modifier.width(12.dp), style = AppTheme.body(12, color = c.inkSoft))
        Text(label, Modifier.weight(1f), style = AppTheme.body(if (depth == 0) 14 else 13, color = c.ink))
        if (delta != null) Text(delta, style = AppTheme.body(11, color = deltaColor))
        Text(fmtMoney(total), style = AppTheme.mono(if (depth == 0) 14 else 13, color = c.ink))
    }
}

@Composable
private fun Purchases(ui: OverviewUi, key: String, onOpenReceipt: (String) -> Unit) {
    val c = AppTheme.colors
    Column(Modifier.fillMaxWidth().padding(start = 40.dp, top = 2.dp, bottom = 4.dp)) {
        val detail = ui.groupDetails[key]
        when {
            key in ui.loadingGroups || detail == null -> Text("Loading…", style = AppTheme.body(13, color = c.inkSoft))
            detail.purchases.isEmpty() -> Text("No purchases found.", style = AppTheme.body(13, color = c.inkSoft))
            else -> Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp)).background(c.field).border(1.dp, c.rule, RoundedCornerShape(4.dp)).padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (detail.history.size > 1) PriceHistoryChart(detail.history)
                detail.purchases.forEach { p ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text(p.translationEn ?: p.nameDe ?: "", style = AppTheme.body(12, color = c.ink), maxLines = 2)
                            Text("${p.date ?: ""}  ${p.store ?: ""}", style = AppTheme.mono(10, color = c.inkSoft), maxLines = 1)
                        }
                        Text(fmtMoney(p.totalPrice), style = AppTheme.mono(12, color = c.ink))
                        Text(
                            "Edit",
                            Modifier.clip(RoundedCornerShape(3.dp)).border(1.dp, c.rule, RoundedCornerShape(3.dp)).clickable { onOpenReceipt(p.receiptId) }
                                .padding(horizontal = 8.dp, vertical = 3.dp),
                            style = AppTheme.body(11, color = c.inkSoft),
                        )
                    }
                }
            }
        }
    }
}
