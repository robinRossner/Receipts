package com.robinrossner.receipts.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Dangerous
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.LinkOff
import androidx.compose.material.icons.outlined.NetworkCheck
import androidx.compose.material.icons.outlined.Save
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.BuildConfig
import com.robinrossner.receipts.data.api.ServerUrl
import com.robinrossner.receipts.data.api.SyncCapabilities
import com.robinrossner.receipts.data.sync.ConnectionTest
import com.robinrossner.receipts.data.sync.SyncPhase
import com.robinrossner.receipts.ui.components.AppConfirmDialog
import com.robinrossner.receipts.ui.components.AppTextField
import com.robinrossner.receipts.ui.components.AppTopBar
import com.robinrossner.receipts.ui.components.MiniSpinner
import com.robinrossner.receipts.ui.components.NoteBox
import com.robinrossner.receipts.ui.components.RuleDivider
import com.robinrossner.receipts.ui.components.SectionLabel
import com.robinrossner.receipts.ui.components.formatFileSize
import com.robinrossner.receipts.ui.settings.SettingsLogic
import com.robinrossner.receipts.ui.settings.dismissKeyboardOnDrag
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

/**
 * Setup and status: the server address and the receipts token (kept encrypted with the Android Keystore), a connection
 * test, sync status and the photo cache. Cloud only: there are no AI settings on the phone.
 */
@Composable
fun SettingsScreen(container: AppContainer) {
    val colors = AppTheme.colors
    val settings = container.settings
    val coordinator = container.coordinator
    val sync by coordinator.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    var url by remember { mutableStateOf(settings.serverUrl) }
    var tokenInput by remember { mutableStateOf("") }
    var hasToken by remember { mutableStateOf(settings.vault.contains()) }
    var testing by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<ConnectionTest?>(null) }
    var cacheBytes by remember { mutableLongStateOf(0L) }
    var confirmClear by remember { mutableStateOf(false) }

    val urlValid = ServerUrl.apiBase(url, BuildConfig.DEBUG) != null
    val urlProblem = SettingsLogic.urlProblem(url, urlValid, BuildConfig.DEBUG)
    val typedToken = tokenInput.trim()
    val canSave = SettingsLogic.canSave(urlValid, hasToken, typedToken)

    suspend fun refreshCache() { cacheBytes = withContext(Dispatchers.IO) { coordinator.photoCacheBytes } }

    // The cache size is read on appear and whenever the sync changes phase; a finished sync also ends the "Saved. Syncing…" note.
    LaunchedEffect(sync.phase) {
        refreshCache()
        if (SettingsLogic.clearSavedNote(result?.message, sync.phase == SyncPhase.IDLE)) result = null
    }

    fun save() {
        focus.clearFocus()
        settings.serverUrl = url.trim()
        if (typedToken.isNotEmpty()) {
            if (!settings.vault.save(typedToken)) { result = ConnectionTest(false, "The token could not be stored in the Android Keystore."); return }
            tokenInput = ""
        }
        hasToken = settings.vault.contains()
        settings.enabled = true   // cloud only: saving the server turns sync on
        coordinator.configure()
        result = ConnectionTest(true, SettingsLogic.SAVED_NOTE)
    }

    fun disconnect() {
        settings.vault.delete(); hasToken = false; settings.enabled = false; coordinator.configure(); result = null
    }

    fun test() {
        focus.clearFocus()
        testing = true
        scope.launch {
            result = coordinator.testConnection(url, typedToken.ifEmpty { settings.vault.read() })
            testing = false
        }
    }

    Column(Modifier.fillMaxSize().background(colors.desk)) {
        AppTopBar("Settings", titleSize = 20f)
        Column(
            Modifier.weight(1f).fillMaxWidth().imePadding().dismissKeyboardOnDrag().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            SettingsSection(
                "Server",
                "Your own receipts backend. Photos are sent there and read by it; this phone has no AI of its own. The token is stored encrypted with the Android Keystore.",
                buildList<@Composable () -> Unit> {
                    add {
                        FieldRow("Server URL") {
                            AppTextField(
                                url, { url = it }, Modifier.fillMaxWidth().testTag("serverURLField"),
                                textStyle = AppTheme.mono(14), placeholder = "https://receipts.example.com", boxed = false,
                                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                            )
                        }
                    }
                    add {
                        FieldRow("Receipts token") {
                            AppTextField(
                                tokenInput, { tokenInput = it }, Modifier.fillMaxWidth().testTag("tokenField"),
                                textStyle = AppTheme.mono(14), placeholder = SettingsLogic.tokenPlaceholder(hasToken), boxed = false,
                                visualTransformation = PasswordVisualTransformation(),
                                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                            )
                        }
                    }
                    if (urlProblem != null) add { RowFrame { Text(urlProblem, style = AppTheme.body(13, color = colors.red)) } }
                    add { ActionRow("Save", Icons.Outlined.Save, ::save, enabled = canSave, testTag = "saveSettingsButton") }
                    if (hasToken) add { ActionRow("Remove token and disconnect", Icons.Outlined.LinkOff, ::disconnect, color = colors.red, testTag = "disconnectButton") }
                },
            )

            SettingsSection(
                null, null,
                buildList<@Composable () -> Unit> {
                    add {
                        ActionRow(
                            "Test connection", Icons.Outlined.NetworkCheck, ::test, enabled = !testing && canSave, testTag = "testConnectionButton", busy = testing,
                            busyLabel = "Testing…",
                        )
                    }
                    result?.let { r ->
                        add {
                            RowFrame {
                                NoteBox(
                                    if (r.ok) Icons.Outlined.CheckCircle else Icons.Outlined.Dangerous, r.message,
                                    if (r.ok) colors.greenText else colors.red, if (r.ok) colors.greenBg else colors.redBg,
                                    testTag = "testConnectionResult",
                                )
                            }
                        }
                    }
                },
            )

            if (coordinator.isConfigured) SettingsSection(
                "Sync", "Syncs when the app opens, shortly after edits, and when you pull the list down.",
                buildList<@Composable () -> Unit> {
                    add {
                        ValueRow("Last sync") {
                            Text(
                                sync.lastSyncAt?.let { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it.toEpochMilli())) } ?: "Never",
                                Modifier.testTag("lastSyncValue"), style = AppTheme.mono(13, color = colors.inkSoft),
                            )
                        }
                    }
                    if (sync.unsentChanges > 0) add { ValueRow("Not sent yet") { Capsule(SettingsLogic.changeCount(sync.unsentChanges), colors.ink, colors.desk) } }
                    if (sync.rejectedRecords > 0) add {
                        RowFrame {
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                    Text("Refused by the server", style = AppTheme.body(15, color = colors.ink))
                                    Spacer(Modifier.weight(1f))
                                    Capsule(SettingsLogic.recordCount(sync.rejectedRecords), colors.red, colors.redBg)
                                }
                                Text("Edit such a record again to send it again.", style = AppTheme.body(12.5f, color = colors.inkSoft))
                            }
                        }
                    }
                    sync.lastError?.let { error -> add { RowFrame { Text(error, style = AppTheme.body(13, color = colors.red)) } } }
                    add {
                        ActionRow(
                            "Sync now", Icons.Outlined.Sync,
                            { scope.launch { coordinator.syncNow(); refreshCache() } },
                            enabled = sync.phase != SyncPhase.SYNCING, testTag = "syncNowButton", busy = sync.phase == SyncPhase.SYNCING, busyLabel = "Syncing…",
                        )
                    }
                },
            )

            SettingsSection(
                "Photos", SettingsLogic.photosFooter(formatFileSize(SyncCapabilities.MOBILE.photoCacheBytes)),
                buildList<@Composable () -> Unit> {
                    add { ValueRow("Cached photos") { Text(formatFileSize(cacheBytes), Modifier.testTag("cacheSize"), style = AppTheme.mono(13, color = colors.inkSoft)) } }
                    add { ActionRow("Clear cached photos", Icons.Outlined.Delete, { confirmClear = true }, color = colors.red, testTag = "clearCacheButton") }
                },
            )

            SettingsSection(
                "About", null,
                listOf {
                    RowFrame {
                        Text(
                            "Item categories (the dictionary) are edited on the Mac; changes sync here. Items without a category can be sorted out under Overview.",
                            style = AppTheme.body(14, color = colors.inkSoft),
                        )
                    }
                },
            )
        }
    }

    if (confirmClear) AppConfirmDialog(
        title = "Clear cached photos?",
        message = "Receipts keep their data. A photo the server still holds is downloaded again when you open it; one that is only on your laptop shows “This photo is on your laptop”.",
        confirmLabel = "Clear cached photos", destructive = true, confirmTestTag = "confirmClearCache",
        onConfirm = {
            confirmClear = false
            scope.launch { coordinator.clearPhotoCache(); refreshCache() }
        },
        onDismiss = { confirmClear = false },
    )
}

// ---------------------------------------------------------------------------------------------------------------------
// Form pieces (the iPhone's grouped Form: header, a paper card of rows, footer)

@Composable
private fun SettingsSection(title: String?, footer: String?, rows: List<@Composable () -> Unit>) {
    val colors = AppTheme.colors
    Column(Modifier.fillMaxWidth()) {
        title?.let { SectionLabel(it, Modifier.padding(start = 16.dp, bottom = 6.dp)) }
        Column(Modifier.fillMaxWidth().background(colors.paper, RoundedCornerShape(10.dp))) {
            rows.forEachIndexed { index, row ->
                if (index > 0) RuleDivider(Modifier.padding(start = 16.dp))
                row()
            }
        }
        footer?.let { Text(it, Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp), style = AppTheme.body(12.5f, color = colors.label)) }
    }
}

/** A row's frame: at least 44dp high, 16dp at the sides, 10dp above and below. */
@Composable
private fun RowFrame(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.Center) { content() }
}

@Composable
private fun FieldRow(caption: String, field: @Composable () -> Unit) {
    RowFrame {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(caption, style = AppTheme.body(12, color = AppTheme.colors.inkSoft))
            field()
        }
    }
}

@Composable
private fun ValueRow(title: String, value: @Composable () -> Unit) {
    RowFrame {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = AppTheme.body(15, color = AppTheme.colors.ink))
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(8.dp))
            value()
        }
    }
}

@Composable
private fun Capsule(text: String, color: Color, background: Color) {
    Text(
        text, Modifier.background(background, CircleShape).padding(horizontal = 8.dp, vertical = 3.dp),
        style = AppTheme.mono(12, FontWeight.Medium, color),
    )
}

/** A button of the iPhone Form: plain `ink` text (Medium 17) with an optional icon, the whole row tappable; dimmed when disabled. */
@Composable
private fun ActionRow(
    label: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    color: Color = AppTheme.colors.ink,
    testTag: String? = null,
    busy: Boolean = false,
    busyLabel: String = "",
) {
    Row(
        modifier
            .let { if (testTag != null) it.testTag(testTag) else it }
            .fillMaxWidth().alpha(if (enabled) 1f else 0.4f)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .heightIn(min = 44.dp).padding(horizontal = 16.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        if (busy) {
            MiniSpinner(16.dp, color, 2.dp)
            Text(busyLabel, style = AppTheme.body(17, FontWeight.Medium, color))
        } else {
            Icon(icon, null, Modifier.size(20.dp), tint = color)
            Text(label, style = AppTheme.body(17, FontWeight.Medium, color))
        }
    }
}
