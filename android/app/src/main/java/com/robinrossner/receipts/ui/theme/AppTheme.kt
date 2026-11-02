package com.robinrossner.receipts.ui.theme

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.DatePickerColors
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.TimePickerColors
import androidx.compose.material3.TimePickerDefaults
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The warm paper look of the iPhone app (`Sources/ReceiptsiOS/Theme.swift`): paper on a desk, ink, a red pen and a green
 * stamp, with the same dark counterpart (dark paper, light ink). Token names follow the iPhone `Theme`.
 */
@Immutable
class AppColors(
    /** Cards, bars, rows, the tab bar. */
    val paper: Color,
    /** Screen background and sheet background. */
    val desk: Color,
    /** Primary text, filled buttons, tint. */
    val ink: Color,
    /** Secondary text and icons. */
    val inkSoft: Color,
    /** Small text directly on the desk, section labels. */
    val label: Color,
    /** "Look at this": warnings, the unreviewed bar, destructive text. */
    val red: Color,
    /** Error bar background (white text in both modes). */
    val errorBar: Color,
    /** Warning box, banner, flagged item tint. */
    val redBg: Color,
    /** Text on a `red` fill (a badge). */
    val onRed: Color,
    /** "Looks good" fill, swipe-confirm, dot. */
    val green: Color,
    /** Green text on paper, "Reviewed". */
    val greenText: Color,
    /** Reviewed status, success notes. */
    val greenBg: Color,
    /** Text on a `green` fill. */
    val onGreen: Color,
    /** 1dp borders and dividers. */
    val rule: Color,
    /** Text field and picker background. */
    val field: Color,
    /** Text on an `ink` coloured fill. */
    val onInk: Color,
    /** Chart series, five of them, never red. */
    val series: List<Color>,
    /** The "Other" series and the no-sync dot. */
    val seriesOther: Color,
    /** Photo viewer backdrop (both modes). */
    val photoBackdrop: Color,
    /** Dimming behind sheets drawn by hand. */
    val scrim: Color,
    /** [SegmentedControl][com.robinrossner.receipts.ui.components.SegmentedControl] track. */
    val segmentTrack: Color,
    /** Selected segment of the segmented control. */
    val segmentThumb: Color,
    val isDark: Boolean,
)

private fun hex(v: Long) = Color(0xFF000000 or v)

val LightAppColors = AppColors(
    paper = hex(0xFAF7EE), desk = hex(0xE6E1D2), ink = hex(0x2B2823), inkSoft = hex(0x665F53), label = hex(0x575146),
    red = hex(0xB33A3A), errorBar = hex(0xB33A3A), redBg = hex(0xFBEAE8), onRed = hex(0xFFFFFF),
    green = hex(0x3A6B4B), greenText = hex(0x2F6341), greenBg = hex(0xE6F0E6), onGreen = hex(0xFFFFFF),
    rule = hex(0xCFC8B3), field = hex(0xFFFFFF), onInk = hex(0xFFFFFF),
    series = listOf(hex(0x3F6B4F), hex(0xC28B2C), hex(0x3F6A8A), hex(0x7A4E7E), hex(0x9C6B4A)), seriesOther = hex(0x9A9484),
    photoBackdrop = hex(0x333333), scrim = Color.Black.copy(alpha = 0.32f),
    segmentTrack = hex(0x2B2823).copy(alpha = 0.08f), segmentThumb = hex(0xFFFFFF), isDark = false,
)

val DarkAppColors = AppColors(
    paper = hex(0x2A2723), desk = hex(0x171512), ink = hex(0xF1ECE1), inkSoft = hex(0xB0A998), label = hex(0xA8A18F),
    red = hex(0xEC8A83), errorBar = hex(0x9E3532), redBg = hex(0x3D2422), onRed = hex(0x2A1412),
    green = hex(0x4F8F67), greenText = hex(0x86C79E), greenBg = hex(0x20302A), onGreen = hex(0x0E1A13),
    rule = hex(0x48433C), field = hex(0x1F1C19), onInk = hex(0x171512),
    series = listOf(hex(0x68AD82), hex(0xE0AE55), hex(0x7DAFD1), hex(0xB88CBC), hex(0xCC9F7E)), seriesOther = hex(0x8C8676),
    photoBackdrop = hex(0x333333), scrim = Color.Black.copy(alpha = 0.32f),
    segmentTrack = hex(0xF1ECE1).copy(alpha = 0.08f), segmentThumb = hex(0x3A3631), isDark = true,
)

val LocalAppColors = staticCompositionLocalOf { LightAppColors }

/** The typewriter-style display voice (store names, titles). The iPhone uses American Typewriter; this is the one place to swap in a bundled slab font. */
val DisplayFont: FontFamily = FontFamily.Serif

/** Ease curves of the iPhone app's `.easeOut` / `.easeInOut` animations. */
val EaseOut = CubicBezierEasing(0f, 0f, 0.58f, 1f)
val EaseInOut = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)

/** Durations (ms) the iPhone animations use. */
object Motion {
    /** Expand/collapse of rows, add form, tree rows, filter toggles, chevron rotation. */
    const val FAST = 150
    /** Recently-deleted toggle, snackbar slide and fade. */
    const val MEDIUM = 200
    /** Overview refresh icon, one full turn. */
    const val REFRESH = 600
    /** Flagged-item highlight fading out. */
    const val HIGHLIGHT = 1200
}

object AppTheme {
    val colors: AppColors
        @Composable @ReadOnlyComposable get() = LocalAppColors.current

    /** Screen-level corner radius of cards, rows and buttons (`Theme.corner`). */
    val corner = 8.dp

    /** Typewriter-style display font for store names and titles (regular weight, as on the iPhone). */
    fun display(size: Float, color: Color = Color.Unspecified) =
        TextStyle(fontFamily = DisplayFont, fontWeight = FontWeight.Normal, fontSize = size.sp, color = color)

    fun display(size: Int, color: Color = Color.Unspecified) = display(size.toFloat(), color)

    fun display(size: TextUnit, color: Color = Color.Unspecified) =
        TextStyle(fontFamily = DisplayFont, fontWeight = FontWeight.Normal, fontSize = size, color = color)

    /** For money amounts, dates and quantities. */
    fun mono(size: Float, weight: FontWeight = FontWeight.Normal, color: Color = Color.Unspecified) =
        TextStyle(fontFamily = FontFamily.Monospace, fontWeight = weight, fontSize = size.sp, color = color)

    fun mono(size: Int, weight: FontWeight = FontWeight.Normal, color: Color = Color.Unspecified) = mono(size.toFloat(), weight, color)

    fun body(size: Float, weight: FontWeight = FontWeight.Normal, color: Color = Color.Unspecified) =
        TextStyle(fontFamily = FontFamily.Default, fontWeight = weight, fontSize = size.sp, color = color)

    fun body(size: Int, weight: FontWeight = FontWeight.Normal, color: Color = Color.Unspecified) = body(size.toFloat(), weight, color)
}

/** Material date picker in ink: selected day `ink` on `onInk`, today outlined in `ink`. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun appDatePickerColors(): DatePickerColors {
    val c = AppTheme.colors
    return DatePickerDefaults.colors(
        containerColor = c.paper, selectedDayContainerColor = c.ink, selectedDayContentColor = c.onInk,
        todayContentColor = c.ink, todayDateBorderColor = c.ink,
        selectedYearContainerColor = c.ink, selectedYearContentColor = c.onInk,
    )
}

/** Material time picker in ink: the dial selector and selected value `ink` on `onInk`. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun appTimePickerColors(): TimePickerColors {
    val c = AppTheme.colors
    return TimePickerDefaults.colors(
        containerColor = c.paper, selectorColor = c.ink, clockDialSelectedContentColor = c.onInk,
        timeSelectorSelectedContainerColor = c.ink, timeSelectorSelectedContentColor = c.onInk,
        periodSelectorSelectedContainerColor = c.ink, periodSelectorSelectedContentColor = c.onInk,
    )
}

@Composable
fun ReceiptsTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val c = if (dark) DarkAppColors else LightAppColors
    val scheme = if (dark) {
        darkColorScheme(
            primary = c.ink, onPrimary = c.onInk, secondary = c.green, onSecondary = c.onGreen,
            background = c.desk, onBackground = c.ink, surface = c.paper, onSurface = c.ink, surfaceVariant = c.field,
            onSurfaceVariant = c.inkSoft, outline = c.rule, outlineVariant = c.rule, error = c.red, onError = c.onRed,
            errorContainer = c.redBg, onErrorContainer = c.red, surfaceContainer = c.paper, surfaceContainerHigh = c.paper,
            surfaceContainerHighest = c.paper, surfaceContainerLow = c.paper, surfaceContainerLowest = c.desk, surfaceTint = c.ink,
            secondaryContainer = c.rule, onSecondaryContainer = c.ink,
        )
    } else {
        lightColorScheme(
            primary = c.ink, onPrimary = c.onInk, secondary = c.green, onSecondary = c.onGreen,
            background = c.desk, onBackground = c.ink, surface = c.paper, onSurface = c.ink, surfaceVariant = c.field,
            onSurfaceVariant = c.inkSoft, outline = c.rule, outlineVariant = c.rule, error = c.red, onError = c.onRed,
            errorContainer = c.redBg, onErrorContainer = c.red, surfaceContainer = c.paper, surfaceContainerHigh = c.paper,
            surfaceContainerHighest = c.paper, surfaceContainerLow = c.paper, surfaceContainerLowest = c.desk, surfaceTint = c.ink,
            secondaryContainer = c.rule, onSecondaryContainer = c.ink,
        )
    }
    CompositionLocalProvider(LocalAppColors provides c) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
