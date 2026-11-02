package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.db.LocalStatus
import com.robinrossner.receipts.data.db.ReceiptSummary
import com.robinrossner.receipts.ui.Processing
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class StatsLogicTest {
    private fun delta(current: Double, previous: Double?, comparison: Boolean = true) = SpendDelta.make(current, previous, comparison, "last month")

    @Test
    fun spendDelta() {
        assertEquals("+12% vs last month", delta(112.0, 100.0)?.text)
        assertEquals(SpendDelta.Trend.UP, delta(112.0, 100.0)?.trend)
        assertEquals("-10% vs last month", delta(90.0, 100.0)?.text)
        assertEquals(SpendDelta.Trend.DOWN, delta(90.0, 100.0)?.trend)
        assertEquals("±0% vs last month", delta(100.2, 100.0)?.text)
        assertEquals(SpendDelta.Trend.FLAT, delta(100.2, 100.0)?.trend)
        assertEquals("new vs last month", delta(5.0, null)?.text)
        assertEquals("new vs last month", delta(5.0, 0.0)?.text)
        assertEquals(SpendDelta.Trend.UP, delta(5.0, 0.0)?.trend)
        assertNull(delta(0.0, 0.0))
        assertNull("custom and all time have no comparison", delta(5.0, 4.0, comparison = false))
        assertEquals("the text-only helper agrees", "+12% vs last month", StatsCalc.deltaText(112.0, 100.0, true, "last month"))
        assertNull(StatsCalc.deltaText(1.0, 1.0, false, "x"))
    }

    @Test
    fun theCursorStopsAtTheCurrentPeriod() {
        val now = LocalDate.parse("2026-10-31")
        val september = LocalDate.parse("2026-09-15")
        assertTrue(OverviewCursor.isLatest(now, byYear = false, today = now))
        assertTrue("any day of the current month", OverviewCursor.isLatest(LocalDate.parse("2026-10-01"), byYear = false, today = now))
        assertFalse(OverviewCursor.isLatest(september, byYear = false, today = now))
        assertTrue(OverviewCursor.isLatest(september, byYear = true, today = now))
        assertFalse(OverviewCursor.isLatest(LocalDate.parse("2025-12-31"), byYear = true, today = now))
        assertTrue("a future month is not before the end either", OverviewCursor.isLatest(LocalDate.parse("2026-11-01"), byYear = false, today = now))
    }

    private fun month(m: String, c: String, t: Double) = MonthCategoryTotal(m, c, t)

    @Test
    fun anAddedCategoryGetsItsOwnSeries() {
        val monthly = listOf(month("2026-03", "Food", 10.0), month("2026-03", "Pets & Animals", 4.0))
        val names = StatsCalc.seriesNames(monthly)
        assertEquals(listOf("Food", "Pets & Animals"), names)
        assertEquals(setOf("Food", "Pets & Animals"), StatsCalc.stackedBars(monthly, names).flatMap { it.second }.map { it.first }.toSet())
    }

    @Test
    fun beyondFiveCategoriesTheRestFoldIntoOther() {
        val monthly = (1..7).map { month("2026-03", "C$it", it.toDouble()) } + month("2026-03", "Other", 1.0)
        val names = StatsCalc.seriesNames(monthly)
        assertEquals(listOf("C7", "C6", "C5", "C4", "C3", "Other"), names)
        val other = StatsCalc.stackedBars(monthly, names).single().second.first { it.first == "Other" }
        assertEquals("C1, C2 and Other itself", 1.0 + 2.0 + 1.0, other.second, 0.0001)
    }

    @Test
    fun equalTotalsKeepAStableOrder() {
        assertEquals(listOf("A", "B"), StatsCalc.seriesNames(listOf(month("2026-03", "B", 1.0), month("2026-03", "A", 1.0))))
        assertEquals(listOf("A", "B", "C"), StatsCalc.seriesNames(listOf(month("2026-03", "C", 1.0), month("2026-03", "A", 1.0), month("2026-03", "B", 1.0))))
    }

    @Test
    fun aNameWithAPipeIsKeptWhole() {
        val monthly = listOf(month("2026-03", "Food | Drink", 10.0), month("2026-04", "Food | Drink", 5.0), month("2026-04", "Hobby", 1.0))
        val names = StatsCalc.seriesNames(monthly)
        val bars = StatsCalc.stackedBars(monthly, names).flatMap { it.second }
        assertEquals(3, bars.size)
        assertTrue(bars.all { it.first in names })
    }

    @Test
    fun unfinishedStatusesAgreeWithTheProcessingStates() {
        val all = listOf(null, "", "done", "queued", "processing", "failed", LocalStatus.PENDING_UPLOAD, LocalStatus.UPLOAD_FAILED)
        for (status in all) assertEquals(status, Processing.of(status, null) != null, ReceiptStatus.isUnfinished(status))
        assertEquals(setOf("pending_upload", "upload_failed", "queued", "processing", "failed"), ReceiptStatus.UNFINISHED)
    }
}

class ReviewQueueTest {
    private fun summary(id: String, store: String? = null, reviewed: Boolean = false, status: String? = null) =
        ReceiptSummary(id, store, null, null, null, false, if (reviewed) "2026-10-31T10:00:00Z" else null, status, null, null, null)

    @Test
    fun nextIsTheOneAfterThisInTheListElseTheFirst() {
        val list = listOf(summary("1", "A"), summary("2", "B", reviewed = true), summary("3", "C"), summary("4", "D"))
        assertEquals("3", ReviewQueue.next("1", list)?.uuid)
        assertEquals("4", ReviewQueue.next("3", list)?.uuid)
        assertEquals("wraps to the first", "1", ReviewQueue.next("4", list)?.uuid)
        assertEquals("unknown id: the first", "1", ReviewQueue.next("99", list)?.uuid)
    }

    @Test
    fun theQueueSkipsReceiptsStillBeingReadOrFailed() {
        val list = listOf(summary("1", "A"), summary("2", status = "processing"), summary("3", status = "failed"), summary("4", "D"))
        assertEquals("4", ReviewQueue.next("1", list)?.uuid)
        assertNull(ReviewQueue.next("1", listOf(list[0], list[1])))
        for (status in ReceiptStatus.UNFINISHED) assertNull(status, ReviewQueue.next("1", listOf(list[0], summary("2", status = status))))
        assertEquals(listOf("4"), ReviewQueue.waiting(list, "1").map { it.uuid })
    }

    @Test
    fun hintWording() {
        val list = listOf(summary("1", "A"), summary("2", "ALDI SÜD"), summary("3"))
        assertEquals("2 more to review · next: ALDI SÜD", ReviewQueue.hint("1", list))
        assertEquals("the next one has no store yet", "2 more to review", ReviewQueue.hint("2", list))
        assertEquals("Last one to review", ReviewQueue.hint("1", listOf(list[0])))
        assertEquals("Last one to review", ReviewQueue.hint("1", listOf(list[0], summary("2", reviewed = true), summary("3", status = "queued"))))
    }
}
