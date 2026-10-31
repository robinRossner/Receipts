package com.robinrossner.receipts.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

/**
 * The warm paper look of the iPhone app (`Theme/AppTheme.swift`): paper on a desk, ink, a red pen and a green stamp,
 * with the same dark counterpart (dark paper, light ink). Fonts are the closest system ones (serif for headings and
 * store names, monospace for amounts and dates, sans for text).
 */
@Immutable
class AppColors(
    val paper: Color,
    val desk: Color,
    val ink: Color,
    val inkSoft: Color,
    val penRed: Color,
    val penRedBg: Color,
    val stampGreen: Color,
    val rule: Color,
    /** Raised cards on the desk (the purchase drill-down). */
    val card: Color,
    /** Text on an `ink` coloured fill (a filled button). */
    val onInk: Color,
    /** Overview tree rows: second and third level. */
    val treeLevel1: Color,
    val treeLevel2: Color,
    val isDark: Boolean,
)

private fun hex(v: Long) = Color(0xFF000000 or v)

val LightAppColors = AppColors(
    paper = hex(0xF5F1E6), desk = hex(0xDCD6C4), ink = hex(0x2B2823), inkSoft = hex(0x6B655A), penRed = hex(0xB33A3A),
    penRedBg = hex(0xFBEAE8), stampGreen = hex(0x3F6B4F), rule = hex(0xC9C2AC), card = hex(0xFFFFFF), onInk = hex(0xFFFFFF),
    treeLevel1 = hex(0xFBF8F1), treeLevel2 = hex(0xFFFFFF), isDark = false,
)

val DarkAppColors = AppColors(
    paper = hex(0x26231F), desk = hex(0x171512), ink = hex(0xEFEADF), inkSoft = hex(0xA8A18F), penRed = hex(0xE27A74),
    penRedBg = hex(0x3B2321), stampGreen = hex(0x4E8A64), rule = hex(0x45403A), card = hex(0x1E1B18), onInk = hex(0x171512),
    treeLevel1 = hex(0x2D2924), treeLevel2 = hex(0x1E1B18), isDark = true,
)

/** Chart series colours: five categories plus a neutral for "Other". Muted to sit on the paper tone. */
val ChartPalette = listOf(hex(0x3F6B4F), hex(0xB33A3A), hex(0xC28B2C), hex(0x3F6A8A), hex(0x7A4E7E))
val ChartOther = hex(0x9A9484)

val LocalAppColors = staticCompositionLocalOf { LightAppColors }

object AppTheme {
    val colors: AppColors
        @Composable @ReadOnlyComposable get() = LocalAppColors.current

    /** Typewriter-style heading font for store names and titles. */
    fun display(size: TextUnit, color: Color = Color.Unspecified) =
        TextStyle(fontFamily = FontFamily.Serif, fontWeight = FontWeight.Bold, fontSize = size, color = color)

    /** For money amounts, dates and quantities. */
    fun mono(size: Int, weight: FontWeight = FontWeight.Normal, color: Color = Color.Unspecified) =
        TextStyle(fontFamily = FontFamily.Monospace, fontWeight = weight, fontSize = size.sp, color = color)

    fun body(size: Int, weight: FontWeight = FontWeight.Normal, color: Color = Color.Unspecified) =
        TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = weight, fontSize = size.sp, color = color)
}

@Composable
fun ReceiptsTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val c = if (dark) DarkAppColors else LightAppColors
    val scheme = if (dark) {
        darkColorScheme(
            primary = c.ink, onPrimary = c.onInk, secondary = c.stampGreen, onSecondary = Color.White,
            background = c.desk, onBackground = c.ink, surface = c.paper, onSurface = c.ink, surfaceVariant = c.card,
            onSurfaceVariant = c.inkSoft, outline = c.rule, outlineVariant = c.rule, error = c.penRed, onError = c.onInk,
            errorContainer = c.penRedBg, onErrorContainer = c.penRed, surfaceContainer = c.paper, surfaceContainerHigh = c.paper,
            surfaceContainerHighest = c.paper, surfaceContainerLow = c.paper, surfaceContainerLowest = c.desk, surfaceTint = c.ink,
            secondaryContainer = c.rule, onSecondaryContainer = c.ink,
        )
    } else {
        lightColorScheme(
            primary = c.ink, onPrimary = c.onInk, secondary = c.stampGreen, onSecondary = Color.White,
            background = c.desk, onBackground = c.ink, surface = c.paper, onSurface = c.ink, surfaceVariant = c.card,
            onSurfaceVariant = c.inkSoft, outline = c.rule, outlineVariant = c.rule, error = c.penRed, onError = c.onInk,
            errorContainer = c.penRedBg, onErrorContainer = c.penRed, surfaceContainer = c.paper, surfaceContainerHigh = c.paper,
            surfaceContainerHighest = c.paper, surfaceContainerLow = c.paper, surfaceContainerLowest = c.desk, surfaceTint = c.ink,
            secondaryContainer = c.rule, onSecondaryContainer = c.ink,
        )
    }
    CompositionLocalProvider(LocalAppColors provides c) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
