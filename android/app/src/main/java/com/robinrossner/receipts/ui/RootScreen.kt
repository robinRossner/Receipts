package com.robinrossner.receipts.ui

import android.net.Uri
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ReceiptLong
import androidx.compose.material.icons.automirrored.outlined.ReceiptLong
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation.NavController
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.robinrossner.receipts.AppContainer
import com.robinrossner.receipts.data.sync.SyncPhase
import com.robinrossner.receipts.ui.components.ErrorBar
import com.robinrossner.receipts.ui.components.ErrorCenter
import com.robinrossner.receipts.ui.components.LocalErrorCenter
import com.robinrossner.receipts.ui.components.LocalSnackCenter
import com.robinrossner.receipts.ui.components.RuleDivider
import com.robinrossner.receipts.ui.components.SnackCenter
import com.robinrossner.receipts.ui.components.SnackbarBar
import com.robinrossner.receipts.ui.components.SyncBanner
import com.robinrossner.receipts.ui.components.LocalStatusBarHandled
import com.robinrossner.receipts.ui.DetailViewModel
import com.robinrossner.receipts.ui.ListViewModel
import com.robinrossner.receipts.ui.OverviewViewModel
import com.robinrossner.receipts.ui.screens.FlaggedItemsScreen
import com.robinrossner.receipts.ui.screens.OverviewScreen
import com.robinrossner.receipts.ui.screens.ReceiptDetailScreen
import com.robinrossner.receipts.ui.screens.ReceiptListScreen
import com.robinrossner.receipts.ui.screens.SettingsScreen
import com.robinrossner.receipts.ui.theme.AppTheme
import kotlinx.coroutines.launch

private enum class Tab(val route: String, val label: String, val icon: ImageVector, val selectedIcon: ImageVector) {
    Receipts("receipts", "Receipts", Icons.AutoMirrored.Outlined.ReceiptLong, Icons.AutoMirrored.Filled.ReceiptLong),
    Overview("overview", "Overview", Icons.Outlined.BarChart, Icons.Filled.BarChart),
    Settings("settings", "Settings", Icons.Outlined.Settings, Icons.Filled.Settings),
}

/** Receipt screen: `receipt/{uuid}`, optionally `?item={itemDictionaryId}` to open and highlight that item. */
private const val DETAIL = "receipt/{uuid}?item={item}"
private const val FLAGGED = "flagged"

private fun detailRoute(uuid: String, itemDictionaryId: String? = null) =
    "receipt/${Uri.encode(uuid)}" + (itemDictionaryId?.let { "?item=${Uri.encode(it)}" } ?: "")

/**
 * Tabs: Receipts (list, review, capture), Overview (spending charts), Settings (server, sync, photos). The receipt screen and the
 * "Without a category" screen open over them with the tab bar hidden. The banners, the error bar and the undo snackbar live here.
 */
@Composable
fun RootScreen(container: AppContainer) {
    val colors = AppTheme.colors
    val nav = rememberNavController()
    val scope = rememberCoroutineScope()
    val snackCenter = remember { SnackCenter(scope) }
    val errorCenter = remember { ErrorCenter() }
    val listVm: ListViewModel = viewModel(factory = viewModelFactory { initializer { ListViewModel(container) } })
    val overviewVm: OverviewViewModel = viewModel(factory = viewModelFactory { initializer { OverviewViewModel(container) } })
    val listUi by listVm.ui.collectAsStateWithLifecycle()
    val sync by container.coordinator.state.collectAsStateWithLifecycle()
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route
    val showTabs = Tab.entries.any { it.route == route }
    val showSnack = route == Tab.Receipts.route || route == Tab.Overview.route
    val unreviewed = listUi.all.count { it.reviewedAt == null }
    val error = errorCenter.current

    // The Overview shows fresh numbers whenever its tab comes back (after editing a receipt or sorting out items).
    val onOverview = route == Tab.Overview.route
    LaunchedEffect(onOverview) { if (onOverview) overviewVm.reload() }

    CompositionLocalProvider(LocalSnackCenter provides snackCenter, LocalErrorCenter provides errorCenter, LocalStatusBarHandled provides (sync.banners.isNotEmpty() || error != null)) {
        Column(Modifier.fillMaxSize().background(colors.desk).imePadding()) {
            // The first coloured bar takes the status-bar height in its own colour; without any, the screen's top bar does.
            // The server's archive_overdue / disk_warning flags, visible until the cause is gone.
            sync.banners.forEachIndexed { i, text ->
                SyncBanner(text, syncing = sync.phase == SyncPhase.SYNCING, onSyncNow = { scope.launch { container.coordinator.syncNow() } }, topInset = i == 0)
            }
            if (error != null) ErrorBar(error, onDismiss = errorCenter::dismiss, topInset = sync.banners.isEmpty())
            Box(Modifier.weight(1f)) {
                NavHost(
                    nav, startDestination = Tab.Receipts.route, modifier = Modifier.fillMaxSize(),
                    enterTransition = { fadeIn(tween(150)) }, exitTransition = { fadeOut(tween(150)) },
                    popEnterTransition = { fadeIn(tween(150)) }, popExitTransition = { fadeOut(tween(150)) },
                ) {
                    composable(Tab.Receipts.route) {
                        ReceiptListScreen(container, listVm, onOpen = { nav.navigate(detailRoute(it)) }, goToSettings = { nav.switchTab(Tab.Settings.route) })
                    }
                    composable(Tab.Overview.route) {
                        OverviewScreen(
                            overviewVm,
                            onOpenReceipt = { uuid, item -> nav.navigate(detailRoute(uuid, item)) },
                            onOpenFlagged = { nav.navigate(FLAGGED) { launchSingleTop = true } },
                        )
                    }
                    composable(Tab.Settings.route) { SettingsScreen(container) }
                    composable(
                        DETAIL,
                        arguments = listOf(
                            navArgument("uuid") { type = NavType.StringType },
                            navArgument("item") { type = NavType.StringType; nullable = true; defaultValue = null },
                        ),
                    ) { backStack ->
                        val uuid = backStack.arguments?.getString("uuid").orEmpty()
                        val item = backStack.arguments?.getString("item")
                        val vm: DetailViewModel = viewModel(key = "detail-$uuid", factory = viewModelFactory { initializer { DetailViewModel(container, uuid) } })
                        ReceiptDetailScreen(
                            container, vm, listUi,
                            onBack = { if (!nav.popBackStack()) nav.switchTab(Tab.Receipts.route) },
                            // "Looks good" with another receipt waiting: replace this screen, so back leaves to where the review began.
                            onNext = { next -> nav.navigate(detailRoute(next)) { popUpTo(DETAIL) { inclusive = true } } },
                            highlightItemId = item,
                        )
                    }
                    composable(FLAGGED) {
                        FlaggedItemsScreen(
                            container,
                            onBack = { nav.popBackStack() },
                            onOpenReceipt = { uuid, item -> nav.navigate(detailRoute(uuid, item)) },
                        )
                    }
                }
                if (showSnack) {
                    SnackbarBar(
                        snackCenter.current, onUndo = snackCenter::performUndo,
                        modifier = Modifier.align(Alignment.BottomCenter).padding(start = 14.dp, end = 14.dp, bottom = 8.dp),
                    )
                }
            }
            if (showTabs) {
                RuleDivider()
                NavigationBar(containerColor = colors.paper, contentColor = colors.ink, tonalElevation = 0.dp) {
                    Tab.entries.forEach { tab ->
                        val selected = route == tab.route
                        NavigationBarItem(
                            selected = selected, onClick = { nav.switchTab(tab.route) },
                            icon = {
                                val icon = @Composable { Icon(if (selected) tab.selectedIcon else tab.icon, null) }
                                if (tab == Tab.Receipts && unreviewed > 0) {
                                    BadgedBox(badge = {
                                        Badge(containerColor = colors.red, contentColor = colors.onRed) {
                                            Text(if (unreviewed > 99) "99+" else unreviewed.toString(), style = AppTheme.body(11))
                                        }
                                    }) { icon() }
                                } else icon()
                            },
                            label = { Text(tab.label, style = AppTheme.body(11)) },
                            modifier = Modifier.testTag("tab_${tab.label}"),
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = colors.ink, selectedTextColor = colors.ink, indicatorColor = colors.rule,
                                unselectedIconColor = colors.inkSoft, unselectedTextColor = colors.inkSoft,
                            ),
                        )
                    }
                }
            } else if (route == DETAIL) {
                // The receipt screen has its own action bar in `paper` that runs to the bottom edge.
                Box(Modifier.fillMaxWidth().windowInsetsBottomHeight(WindowInsets.navigationBars).background(colors.paper))
            }
        }
    }
}

private fun NavController.switchTab(route: String) {
    navigate(route) {
        popUpTo(graph.findStartDestination().id) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}
