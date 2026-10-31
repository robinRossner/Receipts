package com.robinrossner.receipts

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import com.robinrossner.receipts.ui.RootScreen
import com.robinrossner.receipts.ui.theme.ReceiptsTheme

class MainActivity : ComponentActivity() {
    @OptIn(ExperimentalComposeUiApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as ReceiptsApp).container
        setContent {
            ReceiptsTheme {
                // Test tags show up as resource ids for the emulator end-to-end run (uiautomator).
                androidx.compose.foundation.layout.Box(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) { RootScreen(container) }
            }
        }
    }
}
