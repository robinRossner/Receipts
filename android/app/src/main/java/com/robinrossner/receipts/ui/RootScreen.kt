package com.robinrossner.receipts.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Receipt
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.sync.SyncPhase
import com.robinrossner.receipts.ui.screens.OverviewScreen
import com.robinrossner.receipts.ui.screens.ReceiptDetailScreen
import com.robinrossner.receipts.ui.screens.ReceiptListScreen
import com.robinrossner.receipts.ui.screens.SettingsScreen
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope

private enum class Tab(val route: String, val label: String, val icon: ImageVector) {
    Receipts("receipts", "Receipts", Icons.Default.Receipt),
    Overview("overview", "Overview", Icons.Default.BarChart),
    Settings("settings", "Settings", Icons.Default.Settings),
}

private const val DETAIL = "receipt/{uuid}"

/** Tabs: Receipts (list, review, capture), Overview (spending charts), Settings (server, sync, photos); the review screen opens over them. */
@Composable
fun RootScreen(container: AppContainer) {
    val colors = AppTheme.colors
    val nav = rememberNavController()
    val listVm: ListViewModel = viewModel(factory = viewModelFactory { initializer { ListViewModel(container) } })
    val overviewVm: OverviewViewModel = viewModel(factory = viewModelFactory { initializer { OverviewViewModel(container) } })
    val listUi by listVm.ui.collectAsStateWithLifecycle()
    val sync by container.coordinator.state.collectAsStateWithLifecycle()
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route
    val showTabs = route != DETAIL
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize().background(colors.desk).imePadding()) {
        Box(Modifier.fillMaxWidth().windowInsetsTopHeight(WindowInsets.statusBars).background(colors.paper))
        // The server's archive_overdue / disk_warning flags, visible until the cause is gone.
        sync.banners.forEach { text ->
            Row(Modifier.fillMaxWidth().background(colors.penRedBg).padding(start = 14.dp, top = 8.dp, bottom = 8.dp, end = 4.dp).testTag("syncBanner"), verticalAlignment = Alignment.Top) {
                Text("⚠ $text", Modifier.weight(1f), style = AppTheme.body(12, color = colors.penRed))
                TextButton(onClick = { scope.launch { container.coordinator.syncNow() } }, enabled = sync.phase != SyncPhase.SYNCING) {
                    Text("Sync now", style = AppTheme.body(12, androidx.compose.ui.text.font.FontWeight.Medium, colors.penRed))
                }
            }
        }
        Box(Modifier.weight(1f)) {
            NavHost(nav, startDestination = Tab.Receipts.route, modifier = Modifier.fillMaxSize()) {
                composable(Tab.Receipts.route) {
                    ReceiptListScreen(container, listVm, onOpen = { nav.navigate("receipt/$it") }, goToSettings = { nav.switchTab(Tab.Settings.route) })
                }
                composable(Tab.Overview.route) { OverviewScreen(overviewVm) { nav.navigate("receipt/$it") } }
                composable(Tab.Settings.route) { SettingsScreen(container) }
                composable(DETAIL) { backStack ->
                    val uuid = backStack.arguments?.getString("uuid").orEmpty()
                    val vm: DetailViewModel = viewModel(key = "detail-$uuid", factory = viewModelFactory { initializer { DetailViewModel(container, uuid) } })
                    ReceiptDetailScreen(
                        container, vm, listUi,
                        onBack = { if (!nav.popBackStack()) nav.switchTab(Tab.Receipts.route) },
                        onNext = { next -> nav.navigate("receipt/$next") { popUpTo(DETAIL) { inclusive = true } } },
                    )
                }
            }
        }
        if (showTabs) {
            NavigationBar(containerColor = colors.paper, contentColor = colors.ink) {
                Tab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = route == tab.route, onClick = { nav.switchTab(tab.route) },
                        icon = { Icon(tab.icon, null) }, label = { Text(tab.label, style = AppTheme.body(11)) },
                        modifier = Modifier.testTag("tab_${tab.label}"),
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = colors.onInk, selectedTextColor = colors.ink, indicatorColor = colors.ink,
                            unselectedIconColor = colors.inkSoft, unselectedTextColor = colors.inkSoft,
                        ),
                    )
                }
            }
        } else {
            Box(Modifier.fillMaxWidth().windowInsetsBottomHeight(WindowInsets.navigationBars).background(colors.paper))
        }
    }
}

private fun androidx.navigation.NavController.switchTab(route: String) {
    navigate(route) {
        popUpTo(graph.findStartDestination().id) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}
