package com.robinrossner.receipts.ui

import com.robinrossner.receipts.data.MonthCategoryTotal
import com.robinrossner.receipts.data.PricePoint
import com.robinrossner.receipts.ui.overview.OverviewLogic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.YearMonth
import java.util.Locale

class OverviewLogicTest {
    private fun m(month: String) = MonthCategoryTotal(month, "Food", 1.0)

    @Test
    fun theMonthAxisSpansFirstToLastMonthWithDataGapsIncluded() {
        val axis = OverviewLogic.monthAxis(listOf(m("2026-03"), m("2026-06"), m("2026-04")))
        assertEquals(listOf("2026-03", "2026-04", "2026-05", "2026-06"), axis.map { it.toString() })
        assertEquals(listOf(YearMonth.parse("2026-10")), OverviewLogic.monthAxis(listOf(m("2026-10"))))
        assertTrue(OverviewLogic.monthAxis(emptyList()).isEmpty())
        assertEquals("a year boundary", listOf("2025-12", "2026-01"), OverviewLogic.monthAxis(listOf(m("2026-01"), m("2025-12"))).map { it.toString() })
    }

    @Test
    fun aLoneMonthGetsAFixedBarOtherwiseSeventyPercentOfTheSlot() {
        assertEquals(36f, OverviewLogic.barWidth(300f, 1, 36f), 0.001f)
        assertEquals(70f, OverviewLogic.barWidth(100f, 4, 36f), 0.001f)
    }

    @Test
    fun upToTwelveMonthsGetOneLetterEachBeyondThatAboutSixShortLabels() {
        val (few, letters) = OverviewLogic.monthLabelIndices(12)
        assertEquals((0..11).toList(), few)
        assertTrue(letters)
        val (many, long) = OverviewLogic.monthLabelIndices(25)
        assertFalse(long)
        assertEquals(listOf(0, 5, 10, 14, 19, 24), many)
        assertEquals("two months, two labels", listOf(0, 1), OverviewLogic.monthLabelIndices(2).first)
        assertTrue(OverviewLogic.monthLabelIndices(0).first.isEmpty())
    }

    @Test
    fun monthLabelsAreLettersOrAbbreviatedMonthAndYear() {
        assertEquals("O", OverviewLogic.monthLabel(YearMonth.of(2026, 10), letters = true, locale = Locale.US))
        assertEquals("Oct 26", OverviewLogic.monthLabel(YearMonth.of(2026, 10), letters = false, locale = Locale.US))
        assertEquals("Jan 05", OverviewLogic.monthLabel(YearMonth.of(2105, 1), letters = false, locale = Locale.US))
    }

    @Test
    fun niceTicksStartAtZeroAndCoverTheMaximum() {
        assertEquals(listOf(0.0, 50.0, 100.0, 150.0, 200.0), OverviewLogic.niceTicks(180.0))
        assertEquals(listOf(0.0, 25.0, 50.0, 75.0, 100.0).take(5).size, OverviewLogic.niceTicks(100.0).size)
        assertEquals(listOf(0.0, 1.0), OverviewLogic.niceTicks(0.0))
        val ticks = OverviewLogic.niceTicks(1234.56)
        assertTrue(ticks.last() >= 1234.56)
        assertTrue(ticks.size in 3..6)
        assertEquals(0.0, ticks.first(), 0.0)
    }

    @Test
    fun priceTicksStayInsideTheDomainWithoutForcingZero() {
        val ticks = OverviewLogic.ticksWithin(1.9, 2.7, 4)
        assertTrue(ticks.all { it in 1.9..2.7 })
        assertTrue(ticks.size in 3..6)
        assertTrue("zero is not part of the scale", ticks.none { it == 0.0 })
        assertEquals(listOf(5.0), OverviewLogic.ticksWithin(5.0, 5.0))
    }

    @Test
    fun theHistoryDomainHasTenPercentAirAndFlatPricesStillSpan() {
        val pts = listOf(PricePoint(LocalDate.of(2026, 1, 1), "A", 2.0), PricePoint(LocalDate.of(2026, 2, 1), "A", 3.0))
        val (lo, hi) = OverviewLogic.priceDomain(pts)
        assertEquals(1.9, lo, 1e-9)
        assertEquals(3.1, hi, 1e-9)
        val (flatLo, flatHi) = OverviewLogic.priceDomain(pts.map { it.copy(unitPrice = 2.0) })
        assertTrue(flatLo < 2.0 && flatHi > 2.0)
    }

    @Test
    fun dateTicksAreEvenlySpreadAndLabelledMonthDay() {
        val start = LocalDate.of(2026, 10, 1).toEpochDay()
        val end = LocalDate.of(2026, 10, 31).toEpochDay()
        val ticks = OverviewLogic.dateTicks(start, end, 3)
        assertEquals(listOf(start, start + 15, end), ticks)
        assertEquals(listOf(start), OverviewLogic.dateTicks(start, start, 3))
        assertEquals("Oct 3", OverviewLogic.dateLabel(LocalDate.of(2026, 10, 3).toEpochDay(), Locale.US))
    }

    @Test
    fun storeBarsAreProportionalToThePeakWithAMinimum() {
        assertEquals(200f, OverviewLogic.storeBarWidth(50.0, 50.0, 200f, 3f), 0.001f)
        assertEquals(100f, OverviewLogic.storeBarWidth(25.0, 50.0, 200f, 3f), 0.001f)
        assertEquals(3f, OverviewLogic.storeBarWidth(0.01, 500.0, 200f, 3f), 0.001f)
        assertEquals("a zero peak does not divide by zero", 3f, OverviewLogic.storeBarWidth(0.0, 0.0, 200f, 3f), 0.001f)
    }

    @Test
    fun priceItemsAreSortedByNameSoColoursStayWithTheItem() {
        val d = LocalDate.of(2026, 1, 1)
        val pts = listOf(PricePoint(d, "Milk", 1.0), PricePoint(d, "Butter", 2.0), PricePoint(d, "Milk", 1.1))
        assertEquals(listOf("Butter", "Milk"), OverviewLogic.priceItems(pts))
    }

    @Test
    fun theRangeLabelUsesEnglishMonthNames() {
        val prev = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            assertEquals("October 2026", OverviewUi(mode = RangeMode.MONTH, cursor = LocalDate.of(2026, 10, 15)).rangeLabel)
        } finally {
            Locale.setDefault(prev)
        }
    }
}
