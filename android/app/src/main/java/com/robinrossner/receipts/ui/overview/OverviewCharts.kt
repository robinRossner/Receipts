package com.robinrossner.receipts.ui.overview

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.data.MonthCategoryTotal
import com.robinrossner.receipts.data.PricePoint
import com.robinrossner.receipts.data.StatsCalc
import com.robinrossner.receipts.ui.components.AppFlowRow
import com.robinrossner.receipts.ui.components.SectionLabel
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.theme.AppTheme

/** Colour of series [index]: `Other` is grey, the rest cycle through the five series colours. */
@Composable
fun seriesColors(names: List<String>): List<Color> {
    val c = AppTheme.colors
    return names.mapIndexed { i, n -> if (n == StatsCalc.OTHER) c.seriesOther else c.series[i % c.series.size] }
}

/** The "Spending by month" bars: one stacked bar per month with data, drawn by hand like the iPhone's Swift Chart. */
@Composable
fun MonthlyChart(monthly: List<MonthCategoryTotal>, series: List<String>, colors: List<Color>, highlightMonth: String?, modifier: Modifier = Modifier) {
    val c = AppTheme.colors
    val measurer = rememberTextMeasurer()
    val axis = remember(monthly) { OverviewLogic.monthAxis(monthly) }
    val bars = remember(monthly, series) { StatsCalc.stackedBars(monthly, series).toMap() }
    val maxTotal = axis.maxOfOrNull { m -> bars[m.toString()]?.sumOf { it.second } ?: 0.0 } ?: 0.0
    val ticks = remember(maxTotal) { OverviewLogic.niceTicks(maxTotal) }
    val top = ticks.last()
    val (labelIndices, letters) = remember(axis.size) { OverviewLogic.monthLabelIndices(axis.size) }
    val yStyle = AppTheme.mono(10, color = c.inkSoft)
    val xStyle = AppTheme.body(10.5f, color = c.inkSoft)
    Canvas(modifier.fillMaxWidth().height(200.dp).testTag("monthChart")) {
        val yLabels = ticks.map { measurer.measure("€${it.toInt()}", yStyle) }
        val leftPad = (yLabels.maxOfOrNull { it.size.width } ?: 0) + 8.dp.toPx()
        val bottomPad = 22.dp.toPx()
        val topPad = 7.dp.toPx()
        val plotW = size.width - leftPad
        val plotH = size.height - bottomPad - topPad
        ticks.forEachIndexed { i, v ->
            val y = topPad + plotH - (v / top * plotH).toFloat()
            drawLine(c.rule.copy(alpha = 0.6f), Offset(leftPad, y), Offset(size.width, y), strokeWidth = 1f)
            val l = yLabels[i]
            drawText(l, topLeft = Offset(leftPad - l.size.width - 6.dp.toPx(), y - l.size.height / 2f))
        }
        if (axis.isEmpty()) return@Canvas
        val slot = plotW / axis.size
        val barW = OverviewLogic.barWidth(slot, axis.size, OverviewLogic.SINGLE_BAR_DP.dp.toPx())
        axis.forEachIndexed { i, month ->
            val slotStart = leftPad + slot * i
            if (axis.size <= OverviewLogic.LETTER_LIMIT || i in labelIndices) {
                drawLine(c.rule.copy(alpha = 0.4f), Offset(slotStart, topPad), Offset(slotStart, topPad + plotH), strokeWidth = 1f)
            }
            val x = slotStart + (slot - barW) / 2
            val dim = highlightMonth != null && month.toString() != highlightMonth
            var y = topPad + plotH
            bars[month.toString()]?.forEach { (name, value) ->
                val h = (value / top * plotH).toFloat()
                val color = colors[series.indexOf(name).coerceAtLeast(0)].copy(alpha = if (dim) 0.45f else 1f)
                drawRect(color, Offset(x, y - h), Size(barW, h))
                y -= h
            }
            if (i in labelIndices) {
                val label = measurer.measure(OverviewLogic.monthLabel(month, letters), xStyle)
                val cx = slotStart + slot / 2
                val lx = (cx - label.size.width / 2f).coerceIn(leftPad, (size.width - label.size.width).coerceAtLeast(leftPad))
                drawText(label, topLeft = Offset(lx, topPad + plotH + 5.dp.toPx()))
            }
        }
    }
}

/** Colour swatch and name per series (squares in the monthly chart) or item (circles in the price history). */
@Composable
fun ChartLegend(names: List<String>, colors: List<Color>, circles: Boolean = false) {
    AppFlowRow(12.dp) {
        names.forEachIndexed { i, n ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                if (circles) Box(Modifier.size(8.dp).background(colors[i], CircleShape))
                else Box(Modifier.size(10.dp).background(colors[i], RoundedCornerShape(2.dp)))
                Text(n, style = AppTheme.body(12, color = AppTheme.colors.inkSoft))
            }
        }
    }
}

/** Unit price over time, one line per item, in a dashed container with a legend. */
@Composable
fun PriceHistory(points: List<PricePoint>) {
    val c = AppTheme.colors
    val names = remember(points) { OverviewLogic.priceItems(points) }
    val colors = names.indices.map { c.series[it % c.series.size] }
    val measurer = rememberTextMeasurer()
    val (lo, hi) = remember(points) { OverviewLogic.priceDomain(points) }
    val yTicks = remember(lo, hi) { OverviewLogic.ticksWithin(lo, hi, 4) }
    val firstDay = points.minOf { it.date.toEpochDay() }
    val lastDay = points.maxOf { it.date.toEpochDay() }
    val xTicks = remember(firstDay, lastDay) { OverviewLogic.dateTicks(firstDay, lastDay, 3) }
    val yStyle = AppTheme.mono(10, color = c.inkSoft)
    val xStyle = AppTheme.body(10, color = c.inkSoft)
    Column(
        Modifier.fillMaxWidth().dashedBorder(c.rule, 6.dp).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        SectionLabel("Price history (unit price, all time)")
        Canvas(Modifier.fillMaxWidth().height(140.dp).testTag("priceChart")) {
            val yLabels = yTicks.map { measurer.measure(fmtMoney(it), yStyle) }
            val leftPad = (yLabels.maxOfOrNull { it.size.width } ?: 0) + 8.dp.toPx()
            val bottomPad = 18.dp.toPx()
            val inset = 6.dp.toPx()
            val plotW = size.width - leftPad - inset
            val plotH = size.height - bottomPad - 4.dp.toPx()
            val span = (lastDay - firstDay).coerceAtLeast(1)
            fun px(day: Long) = leftPad + if (lastDay == firstDay) plotW / 2 else plotW * (day - firstDay).toFloat() / span
            fun py(v: Double) = 2.dp.toPx() + plotH - (plotH * (v - lo) / (hi - lo)).toFloat()
            yTicks.forEachIndexed { i, v ->
                val y = py(v)
                drawLine(c.rule.copy(alpha = 0.6f), Offset(leftPad, y), Offset(size.width, y), strokeWidth = 1f)
                val l = yLabels[i]
                drawText(l, topLeft = Offset(leftPad - l.size.width - 6.dp.toPx(), y - l.size.height / 2f))
            }
            xTicks.forEach { day ->
                val x = px(day)
                drawLine(c.rule.copy(alpha = 0.4f), Offset(x, 2.dp.toPx()), Offset(x, 2.dp.toPx() + plotH), strokeWidth = 1f)
                val l = measurer.measure(OverviewLogic.dateLabel(day), xStyle)
                val lx = (x - l.size.width / 2f).coerceIn(leftPad - 4.dp.toPx(), (size.width - l.size.width).coerceAtLeast(0f))
                drawText(l, topLeft = Offset(lx, 2.dp.toPx() + plotH + 4.dp.toPx()))
            }
            names.forEachIndexed { i, name ->
                val pts = points.filter { it.item == name }.sortedBy { it.date }
                val path = Path()
                pts.forEachIndexed { k, p ->
                    val o = Offset(px(p.date.toEpochDay()), py(p.unitPrice))
                    if (k == 0) path.moveTo(o.x, o.y) else path.lineTo(o.x, o.y)
                }
                drawPath(path, colors[i], style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                pts.forEach { drawCircle(colors[i], 2.5.dp.toPx(), Offset(px(it.date.toEpochDay()), py(it.unitPrice))) }
            }
        }
        ChartLegend(names, colors, circles = true)
    }
}

/** 1dp dashed outline (4 on, 3 off) with rounded corners. */
private fun Modifier.dashedBorder(color: Color, radius: Dp): Modifier = drawBehind {
    val stroke = Stroke(width = 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx())))
    val half = stroke.width / 2
    drawRoundRect(
        color, topLeft = Offset(half, half), size = Size(size.width - stroke.width, size.height - stroke.width),
        cornerRadius = CornerRadius(radius.toPx()), style = stroke,
    )
}
