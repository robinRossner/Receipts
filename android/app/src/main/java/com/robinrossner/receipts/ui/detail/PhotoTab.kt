package com.robinrossner.receipts.ui.detail

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BrokenImage
import androidx.compose.material.icons.outlined.ZoomIn
import androidx.compose.material.icons.outlined.ZoomOut
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.ui.PhotoUi
import com.robinrossner.receipts.ui.components.AppIconButton
import com.robinrossner.receipts.ui.components.MiniSpinner
import com.robinrossner.receipts.ui.components.RuleDivider
import com.robinrossner.receipts.ui.components.SectionLabel
import com.robinrossner.receipts.ui.components.rememberBitmap
import com.robinrossner.receipts.ui.theme.AppTheme
import com.robinrossner.receipts.ui.theme.EaseOut
import com.robinrossner.receipts.ui.theme.Motion
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.max
import kotlin.math.min

/** The Photo tab (`ReceiptPhotoView`, iPhone branch): zoom toolbar, then the photo on a dark backdrop, or why there is none. */
@Composable
fun PhotoTab(container: AppContainer, photo: PhotoUi, modifier: Modifier = Modifier) {
    val colors = AppTheme.colors
    val file = (photo as? PhotoUi.Ready)?.let { container.paths.resolve(it.path) }
    val bitmap = rememberBitmap(file)
    val pixelWidth by produceState(0, file?.path, file?.lastModified()) {
        value = if (file == null) 0 else withContext(Dispatchers.IO) { originalWidth(file) }
    }
    val loaded = bitmap != null

    var zoom by remember(file?.path) { mutableFloatStateOf(PhotoZoom.MIN) }
    var animateZoom by remember { mutableStateOf(false) }
    var offset by remember(file?.path) { mutableStateOf(Offset.Zero) }
    var actualSize by remember(file?.path) { mutableFloatStateOf(PhotoZoom.MIN) }

    fun zoomTo(value: Float) { animateZoom = true; zoom = PhotoZoom.clamp(value) }

    Column(modifier.fillMaxSize().background(colors.desk)) {
        Row(
            Modifier.fillMaxWidth().background(colors.paper).padding(start = 14.dp, end = 6.dp).alpha(if (loaded) 1f else 0.4f),
            horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            SectionLabel("Photo")
            Spacer(Modifier.weight(1f))
            AppIconButton(Icons.Outlined.ZoomOut, "Zoom out", { zoomTo(PhotoZoom.zoomOut(zoom)) }, tint = colors.ink, iconSize = 16.dp, enabled = loaded)
            ZoomChip("Fit", PhotoZoom.isFit(zoom), loaded) { zoomTo(PhotoZoom.MIN) }
            ZoomChip("100%", PhotoZoom.isActualSize(zoom, actualSize), loaded) { zoomTo(actualSize) }
            AppIconButton(Icons.Outlined.ZoomIn, "Zoom in", { zoomTo(PhotoZoom.zoomIn(zoom)) }, tint = colors.ink, iconSize = 16.dp, enabled = loaded)
        }
        RuleDivider()
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            when {
                photo is PhotoUi.Note -> MissingPhoto(photo.text)
                bitmap == null -> MiniSpinner(16.dp, strokeWidth = 2.dp)
                else -> PhotoPane(
                    bitmap, pixelWidth, zoom, animateZoom, offset,
                    onGesture = { z, o -> animateZoom = false; zoom = z; offset = o },
                    onDoubleTap = { zoomTo(PhotoZoom.doubleTap(zoom)); offset = Offset.Zero },
                    onActualSize = { actualSize = it },
                )
            }
        }
    }
}

@Composable
private fun ZoomChip(text: String, active: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = AppTheme.colors
    Box(
        Modifier
            .defaultMinSize(minWidth = 44.dp, minHeight = 32.dp)
            .background(if (active) colors.rule.copy(alpha = 0.6f) else androidx.compose.ui.graphics.Color.Transparent, RoundedCornerShape(6.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, style = AppTheme.mono(13, if (active) FontWeight.SemiBold else FontWeight.Normal, colors.ink), maxLines = 1)
    }
}

@Composable
private fun MissingPhoto(note: String) {
    val colors = AppTheme.colors
    Column(Modifier.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(Icons.Outlined.BrokenImage, null, Modifier.size(44.dp), tint = colors.label)
        Text(note, Modifier.testTag("photoNote"), style = AppTheme.body(15, color = colors.label), textAlign = TextAlign.Center)
    }
}

/** The photo fitted to the pane, scaled by [zoom] about its centre and dragged by [offset]. Pinch, drag and double tap. */
@Composable
private fun PhotoPane(
    bitmap: Bitmap,
    pixelWidth: Int,
    zoom: Float,
    animate: Boolean,
    offset: Offset,
    onGesture: (zoom: Float, offset: Offset) -> Unit,
    onDoubleTap: () -> Unit,
    onActualSize: (Float) -> Unit,
) {
    val colors = AppTheme.colors
    val density = LocalDensity.current
    val shown by animateFloatAsState(zoom, if (animate) tween(Motion.FAST, easing = EaseOut) else snap(), label = "photoZoom")
    BoxWithConstraints(Modifier.fillMaxSize().background(colors.photoBackdrop).clipToBounds(), contentAlignment = Alignment.Center) {
        val paneW = constraints.maxWidth.toFloat()
        val paneH = constraints.maxHeight.toFloat()
        val aspect = bitmap.width.toFloat() / bitmap.height.toFloat()
        val fitW = min(paneW, paneH * aspect)
        val fitH = fitW / aspect
        val fitWidthDp = fitW / density.density
        val actual = PhotoZoom.actualSize(if (pixelWidth > 0) pixelWidth.toFloat() else bitmap.width.toFloat(), fitWidthDp)
        LaunchedEffect(actual) { onActualSize(actual) }
        val currentZoom by rememberUpdatedState(zoom)
        val currentOffset by rememberUpdatedState(offset)
        val currentGesture by rememberUpdatedState(onGesture)
        val currentDoubleTap by rememberUpdatedState(onDoubleTap)
        val maxX = PhotoZoom.maxPan(fitW, shown, paneW)
        val maxY = PhotoZoom.maxPan(fitH, shown, paneH)
        Box(
            Modifier.fillMaxSize()
                .pointerInput(paneW, paneH) {
                    detectTransformGestures { _, pan, change, _ ->
                        val z = PhotoZoom.clamp(currentZoom * change)
                        val mx = PhotoZoom.maxPan(fitW, z, paneW)
                        val my = PhotoZoom.maxPan(fitH, z, paneH)
                        val o = currentOffset
                        currentGesture(z, Offset((o.x + pan.x).coerceIn(-mx, mx), (o.y + pan.y).coerceIn(-my, my)))
                    }
                }
                .pointerInput(Unit) { detectTapGestures(onDoubleTap = { currentDoubleTap() }) },
        )
        Image(
            bitmap.asImageBitmap(), "Receipt photo",
            Modifier
                .size(with(density) { fitW.toDp() }, with(density) { fitH.toDp() })
                .graphicsLayer(
                    scaleX = shown, scaleY = shown,
                    translationX = offset.x.coerceIn(-maxX, maxX), translationY = offset.y.coerceIn(-maxY, maxY),
                )
                .shadow(8.dp, ambientColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.4f), spotColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.4f))
                .testTag("receiptPhoto"),
            contentScale = ContentScale.Fit,
        )
    }
}

private fun originalWidth(file: File): Int {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    return max(bounds.outWidth, 0)
}
