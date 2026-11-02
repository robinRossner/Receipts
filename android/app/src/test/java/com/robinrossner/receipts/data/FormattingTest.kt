package com.robinrossner.receipts.data

import com.robinrossner.receipts.ui.components.ReceiptDateFormat
import com.robinrossner.receipts.ui.components.fmtMoney
import com.robinrossner.receipts.ui.components.fmtQty
import com.robinrossner.receipts.ui.components.formatFileSize
import com.robinrossner.receipts.ui.components.parseDecimal
import com.robinrossner.receipts.ui.components.trimmedNumber
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate
import java.time.LocalTime

/** The shared formatters must read like the iPhone's (`Formatting.swift`). */
class FormattingTest {
    @Test fun money() {
        assertEquals("—", fmtMoney(null))
        assertEquals("€12.30", fmtMoney(12.3))
        assertEquals("€-1.20", fmtMoney(-1.2))
    }

    @Test fun numbers() {
        assertEquals("2", trimmedNumber(2.0))
        assertEquals("0.5", trimmedNumber(0.5))
        assertEquals("1.25", fmtQty(1.2504))
        assertEquals(2.5, parseDecimal(" 2,5 ")!!, 0.0)
        assertNull(parseDecimal("abc"))
    }

    @Test fun fileSizes() {
        assertEquals("Zero KB", formatFileSize(0))
        assertEquals("1 byte", formatFileSize(1))
        assertEquals("512 bytes", formatFileSize(512))
        assertEquals("46 KB", formatFileSize(45_600))
        assertEquals("1.5 MB", formatFileSize(1_500_000))
        assertEquals("300 MB", formatFileSize(300_000_000))
        assertEquals("1.25 GB", formatFileSize(1_250_000_000))
    }

    @Test fun receiptDates() {
        assertEquals(LocalDate.of(2026, 3, 9), ReceiptDateFormat.parseDate("2026-03-09T10:00"))
        assertEquals(LocalTime.of(7, 5), ReceiptDateFormat.parseTime("07:05:33"))
        assertEquals("07:05", ReceiptDateFormat.time(LocalTime.of(7, 5)))
        assertNull(ReceiptDateFormat.parseDate("nope"))
    }
}
