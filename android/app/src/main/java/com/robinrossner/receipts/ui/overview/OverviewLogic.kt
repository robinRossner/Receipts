package com.robinrossner.receipts.ui.overview

import com.robinrossner.receipts.data.MonthCategoryTotal
import com.robinrossner.receipts.data.PricePoint
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

/** Pure chart arithmetic of the Overview, kept out of the Canvas code so it can be tested. */
object OverviewLogic {
    /** One narrow letter per month slot up to this many months, a few `MMM yy` labels beyond it. */
    const val LETTER_LIMIT = 12
    const val LONG_LABEL_COUNT = 6
    const val SINGLE_BAR_DP = 36f
    const val BAR_FRACTION = 0.7f

    /** Months from the first to the last with data, gaps between included. */
    fun monthAxis(monthly: List<MonthCategoryTotal>): List<YearMonth> {
        val months = monthly.mapNotNull { runCatching { YearMonth.parse(it.month) }.getOrNull() }
        val first = months.minOrNull() ?: return emptyList()
        val last = months.max()
        return generateSequence(first) { if (it < last) it.plusMonths(1) else null }.toList()
    }

    /** Bar width in dp-or-px of the caller's unit: 70% of the slot, a fixed [singleBar] when only one month exists. */
    fun barWidth(slot: Float, months: Int, singleBar: Float): Float = if (months == 1) singleBar else slot * BAR_FRACTION

    /** Indices of the month slots that get a label, and whether the labels are single letters. */
    fun monthLabelIndices(months: Int): Pair<List<Int>, Boolean> {
        if (months <= 0) return emptyList<Int>() to true
        if (months <= LETTER_LIMIT) return (0 until months).toList() to true
        val count = LONG_LABEL_COUNT.coerceAtMost(months)
        val indices = (0 until count).map { (it * (months - 1) / (count - 1).toDouble()).roundToInt() }.distinct()
        return indices to false
    }

    fun monthLabel(month: YearMonth, letters: Boolean, locale: Locale = Locale.getDefault()): String =
        if (letters) month.month.getDisplayName(TextStyle.NARROW, locale)
        else month.month.getDisplayName(TextStyle.SHORT, locale) + " " + String.format(Locale.US, "%02d", month.year % 100)

    /** The tick values 0, step, 2 step ... up to a nice top that covers [maxValue]; about [desired] intervals. */
    fun niceTicks(maxValue: Double, desired: Int = 4): List<Double> {
        if (maxValue <= 0) return listOf(0.0, 1.0)
        val step = niceStep(maxValue / desired)
        val count = ceil(maxValue / step - 1e-9).toInt().coerceAtLeast(1)
        return (0..count).map { it * step }
    }

    /** Tick values inside [lo]..[hi] on a nice step, about [desired] of them. */
    fun ticksWithin(lo: Double, hi: Double, desired: Int = 4): List<Double> {
        if (hi <= lo) return listOf(lo)
        val step = niceStep((hi - lo) / desired)
        val first = ceil(lo / step - 1e-9) * step
        val ticks = generateSequence(first) { it + step }.takeWhile { it <= hi + step * 1e-9 }.toList()
        return ticks.map { Math.round(it / step * 1e6) / 1e6 * step }
    }

    private fun niceStep(raw: Double): Double {
        val magnitude = 10.0.pow(floor(log10(raw)))
        val n = raw / magnitude
        val factor = when { n <= 1.0 -> 1.0; n <= 2.0 -> 2.0; n <= 2.5 -> 2.5; n <= 5.0 -> 5.0; else -> 10.0 }
        return factor * magnitude
    }

    /** The y range of the price chart: the data with about 10% air on both sides, not forced to include zero. */
    fun priceDomain(points: List<PricePoint>): Pair<Double, Double> {
        val lo = points.minOf { it.unitPrice }
        val hi = points.maxOf { it.unitPrice }
        val pad = if (hi > lo) (hi - lo) * 0.1 else max(abs(hi) * 0.1, 0.1)
        return (lo - pad) to (hi + pad)
    }

    /** About [count] evenly spread epoch days from [first] to [last] (one when they coincide). */
    fun dateTicks(first: Long, last: Long, count: Int = 3): List<Long> {
        if (last <= first) return listOf(first)
        return (0 until count).map { first + Math.round((last - first) * it / (count - 1).toDouble()) }.distinct()
    }

    fun dateLabel(epochDay: Long, locale: Locale = Locale.getDefault()): String {
        val d = LocalDate.ofEpochDay(epochDay)
        return d.month.getDisplayName(TextStyle.SHORT, locale) + " " + d.dayOfMonth
    }

    /** Width of a store's bar: proportional to the busiest store, at least [minimum] so the smallest stays visible. */
    fun storeBarWidth(total: Double, peak: Double, full: Float, minimum: Float): Float =
        max(minimum, (full * total / max(peak, 0.01)).toFloat())

    /** Item names of the price history, sorted, so colours stay with an item. */
    fun priceItems(points: List<PricePoint>): List<String> = points.map { it.item }.distinct().sorted()
}
