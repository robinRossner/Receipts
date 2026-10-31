package com.robinrossner.receipts.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.BuildConfig
import com.robinrossner.receipts.data.api.ServerUrl
import com.robinrossner.receipts.data.api.SyncCapabilities
import com.robinrossner.receipts.data.sync.ConnectionTest
import com.robinrossner.receipts.data.sync.SyncPhase
import com.robinrossner.receipts.ui.components.InkButton
import com.robinrossner.receipts.ui.components.LabelValueRow
import com.robinrossner.receipts.ui.components.Paper
import com.robinrossner.receipts.ui.components.QuietButton
import com.robinrossner.receipts.ui.components.SectionLabel
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/**
 * Setup and status: the server address and the receipts token (kept encrypted with the Android Keystore), a connection
 * test, sync status and the photo cache. Cloud only: there are no AI settings on the phone.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(container: AppContainer) {
    val colors = AppTheme.colors
    val settings = container.settings
    val sync by container.coordinator.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    var url by remember { mutableStateOf(settings.serverUrl) }
    var tokenInput by remember { mutableStateOf("") }
    var hasToken by remember { mutableStateOf(settings.vault.contains()) }
    var testing by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<ConnectionTest?>(null) }
    var cacheBytes by remember { mutableLongStateOf(container.coordinator.photoCacheBytes) }
    var confirmClear by remember { mutableStateOf(false) }

    val urlValid = ServerUrl.apiBase(url, BuildConfig.DEBUG) != null
    val urlProblem = if (url.isNotBlank() && !urlValid) {
        if (BuildConfig.DEBUG) "Not a valid address. Use https://… (plain http:// works for the emulator host 10.0.2.2 and localhost in debug builds only)."
        else "Not a valid address. Use https://…"
    } else null
    val typedToken = tokenInput.trim()
    val canSave = urlValid && (hasToken || typedToken.isNotEmpty())

    fun save() {
        focus.clearFocus()
        settings.serverUrl = url
        if (typedToken.isNotEmpty()) {
            if (!settings.vault.save(typedToken)) { result = ConnectionTest(false, "The token could not be stored in the Android Keystore."); return }
            tokenInput = ""
        }
        hasToken = settings.vault.contains()
        settings.enabled = true   // cloud only: saving the server turns sync on
        container.coordinator.configure()
        result = ConnectionTest(true, "Saved. Syncing…")
    }

    Scaffold(
        containerColor = colors.desk,
        contentWindowInsets = androidx.compose.foundation.layout.WindowInsets(0),
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Settings", style = AppTheme.display(20.sp, colors.ink)) },
                windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = colors.paper),
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Section("Server", "Your own receipts backend. Photos are sent there and read by it; this phone has no AI of its own. The token is stored encrypted with the Android Keystore.") {
                Field(url, { url = it }, "Server URL", "https://receipts.example.com", "serverUrlField", KeyboardType.Uri)
                Field(
                    tokenInput, { tokenInput = it }, "Receipts token", if (hasToken) "Saved (encrypted)" else "Paste the token", "tokenField",
                    KeyboardType.Password, password = true,
                )
                urlProblem?.let { Text(it, style = AppTheme.body(12, color = colors.penRed)) }
                InkButton("Save", Modifier.testTag("saveSettingsButton"), enabled = canSave, onClick = ::save)
                if (hasToken) QuietButton("Remove token and disconnect", Modifier.testTag("disconnectButton"), danger = true) {
                    settings.vault.delete(); hasToken = false; settings.enabled = false; container.coordinator.configure(); result = null
                }
            }
            Section(null, null) {
                QuietButton(
                    if (testing) "Testing…" else "Test connection", Modifier.testTag("testConnectionButton"),
                    enabled = !testing && urlValid && (hasToken || typedToken.isNotEmpty()),
                ) {
                    focus.clearFocus()
                    testing = true
                    scope.launch {
                        result = container.coordinator.testConnection(url, typedToken.ifEmpty { settings.vault.read() })
                        testing = false
                    }
                }
                result?.let {
                    Text(
                        (if (it.ok) "✓ " else "✕ ") + it.message, Modifier.testTag("testConnectionResult"),
                        style = AppTheme.body(12, color = if (it.ok) colors.inkSoft else colors.penRed),
                    )
                }
            }
            if (container.coordinator.isConfigured) Section(
                "Sync", "Syncs when the app opens, shortly after edits, and when you pull the list down. Photos upload in the background as soon as the network is back.",
            ) {
                LabelValueRow("Last sync") {
                    Text(
                        sync.lastSyncAt?.let { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it.toEpochMilli())) } ?: "Never",
                        Modifier.testTag("lastSyncValue"), style = AppTheme.body(14, color = colors.ink),
                    )
                }
                if (sync.unsentChanges > 0) LabelValueRow("Not sent yet") { Text("${sync.unsentChanges} change(s)", style = AppTheme.body(14, color = colors.ink)) }
                if (sync.rejectedRecords > 0) {
                    LabelValueRow("Refused by the server") { Text("${sync.rejectedRecords} record(s)", style = AppTheme.body(14, color = colors.ink)) }
                    Text("Edit such a record again to send it again.", style = AppTheme.body(12, color = colors.inkSoft))
                }
                sync.lastError?.let { Text(it, style = AppTheme.body(12, color = colors.penRed)) }
                QuietButton(if (sync.phase == SyncPhase.SYNCING) "Syncing…" else "Sync now", Modifier.testTag("syncNowButton"), enabled = sync.phase != SyncPhase.SYNCING) {
                    scope.launch { container.coordinator.syncNow(); cacheBytes = container.coordinator.photoCacheBytes }
                }
            }
            Section(
                "Photos",
                "This phone keeps up to ${SyncCapabilities.MOBILE.photoCacheBytes / 1_000_000} MB of receipt photos, oldest dropped first. The permanent photo archive is on your laptop: this phone never archives photos or releases the server's copy.",
            ) {
                LabelValueRow("Cached photos") { Text(formatBytes(cacheBytes), Modifier.testTag("cacheSize"), style = AppTheme.body(14, color = colors.ink)) }
                QuietButton("Clear cached photos", Modifier.testTag("clearCacheButton"), danger = true) { confirmClear = true }
            }
            Section("About", null) {
                Text("Item categories (the dictionary) are edited on the Mac; changes sync here.", style = AppTheme.body(12, color = colors.inkSoft))
            }
        }
    }

    if (confirmClear) AlertDialog(
        onDismissRequest = { confirmClear = false },
        title = { Text("Clear cached photos?") },
        text = { Text("Receipts keep their data. A photo the server still holds is downloaded again when you open it; one that is only on your laptop shows “This photo is on your laptop”.") },
        confirmButton = {
            TextButton(onClick = {
                confirmClear = false
                scope.launch { container.coordinator.clearPhotoCache(); cacheBytes = container.coordinator.photoCacheBytes }
            }, modifier = Modifier.testTag("confirmClearCache")) { Text("Clear cached photos", color = colors.penRed) }
        },
        dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } },
    )
}

private fun formatBytes(bytes: Long): String = when {
    bytes < 1_000 -> "$bytes B"
    bytes < 1_000_000 -> String.format(java.util.Locale.US, "%.0f KB", bytes / 1e3)
    else -> String.format(java.util.Locale.US, "%.1f MB", bytes / 1e6)
}

@Composable
private fun Section(title: String?, footer: String?, content: @Composable () -> Unit) {
    val colors = AppTheme.colors
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        title?.let { SectionLabel(it) }
        Paper(Modifier.fillMaxWidth()) { Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { content() } }
        footer?.let { Text(it, style = AppTheme.body(12, color = colors.inkSoft)) }
    }
}

@Composable
private fun Field(value: String, onChange: (String) -> Unit, label: String, placeholder: String, tag: String, type: KeyboardType, password: Boolean = false) {
    val colors = AppTheme.colors
    OutlinedTextField(
        value = value, onValueChange = onChange, singleLine = true, label = { Text(label) },
        placeholder = { Text(placeholder, style = AppTheme.body(14, color = colors.inkSoft)) },
        modifier = Modifier.fillMaxWidth().testTag(tag),
        visualTransformation = if (password) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = type, autoCorrectEnabled = false, capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.None),
        shape = RoundedCornerShape(4.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = colors.ink, unfocusedBorderColor = colors.rule, focusedLabelColor = colors.ink, unfocusedLabelColor = colors.inkSoft,
            focusedContainerColor = colors.card, unfocusedContainerColor = colors.card, cursorColor = colors.ink,
        ),
    )
}
