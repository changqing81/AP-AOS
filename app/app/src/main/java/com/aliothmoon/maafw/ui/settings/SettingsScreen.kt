package com.aliothmoon.maafw.ui.settings

import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.stringResource
import com.aliothmoon.maafw.BuildConfig
import com.aliothmoon.maafw.R
import com.aliothmoon.maafw.constant.AndroidVersions
import com.aliothmoon.maafw.domain.RemoteBackend
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import com.aliothmoon.maafw.domain.ThemeMode
import com.aliothmoon.maafw.i18n.AppLocales
import com.aliothmoon.maafw.settings.SettingsIntent
import com.aliothmoon.maafw.settings.SettingsUiState
import com.aliothmoon.maafw.theme.MaaDesignTokens
import com.aliothmoon.maafw.theme.ThemeStyle
import com.aliothmoon.maafw.ui.components.MaaCard
import com.aliothmoon.maafw.ui.components.MaaFieldLabel
import com.aliothmoon.maafw.ui.components.MaaInfoRow
import com.aliothmoon.maafw.ui.components.MaaLabeledControlRow
import com.aliothmoon.maafw.ui.components.MaaNavigationRow
import com.aliothmoon.maafw.ui.components.MaaSingleChoiceFlow
import com.aliothmoon.maafw.ui.components.MaaSwitch
import kotlin.math.round

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: SettingsUiState,
    onIntent: (SettingsIntent) -> Unit,
    // 二级页面与 SAF 都需要 Activity 宿主，导航与弹窗归 AppRoot 那一层
    onOpenAppLog: () -> Unit,
    onOpenAlasLog: () -> Unit,
    onExportAlasLogs: () -> Unit,
    onExportLauncherLogs: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = {
                Text(
                    text = stringResource(R.string.nav_settings),
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.SemiBold,
                )
            },
            windowInsets = WindowInsets(0, 0, 0, 0),
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = MaterialTheme.colorScheme.background,
                titleContentColor = MaterialTheme.colorScheme.onBackground,
                actionIconContentColor = MaterialTheme.colorScheme.primary,
            ),
        )
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(
                    start = MaaDesignTokens.Spacing.lg,
                    end = MaaDesignTokens.Spacing.lg,
                    top = MaaDesignTokens.Spacing.sm,
                    bottom = MaaDesignTokens.Spacing.lg,
                ),
            verticalArrangement = Arrangement.spacedBy(MaaDesignTokens.Spacing.lg),
        ) {
            DisplayCard(state, onIntent)
            VirtualDisplayFrameRateCard(state, onIntent)
            LogCard(state, onIntent, onOpenAppLog, onOpenAlasLog, onExportAlasLogs, onExportLauncherLogs)
            OtherCard(state, onIntent)
            AboutCard()
        }
    }
}

/** 主题、主题风格、语言：三组都只改观感，合成一张卡（对齐 MaaMeow 的「显示设置」） */
@Composable
private fun DisplayCard(state: SettingsUiState, onIntent: (SettingsIntent) -> Unit) {
    MaaCard(title = stringResource(R.string.settings_section_display), collapsible = true) {
        MaaFieldLabel(stringResource(R.string.settings_theme))
        val modes = listOf(
            ThemeMode.System to stringResource(R.string.settings_follow_system),
            ThemeMode.Light to stringResource(R.string.settings_theme_light),
            ThemeMode.Dark to stringResource(R.string.settings_theme_dark),
        )
        MaaSingleChoiceFlow(
            options = modes,
            selected = state.themeMode,
            onSelect = { onIntent(SettingsIntent.SetThemeMode(it)) },
        )
        Spacer(Modifier.height(MaaDesignTokens.Spacing.sm))
        MaaFieldLabel(stringResource(R.string.settings_theme_style))
        val styles = listOf(
            ThemeStyle.DEFAULT to stringResource(R.string.settings_theme_style_default),
            ThemeStyle.SEMI_DESIGN to stringResource(R.string.settings_theme_style_semi),
        )
        MaaSingleChoiceFlow(
            options = styles,
            selected = state.themeStyle,
            onSelect = { onIntent(SettingsIntent.SetThemeStyle(it)) },
        )
        Spacer(Modifier.height(MaaDesignTokens.Spacing.sm))
        MaaFieldLabel(stringResource(R.string.settings_language))
        LanguageChoice(onIntent)
    }
}

/**
 * 虚拟屏帧率：下次建屏时生效，仅 Android 14+ 支持
 *
 * 档位上限取物理屏当前刷新率并跟随其变化（0 存盘 = 跟随物理屏）；
 * 物理屏读不到刷新率时不给调，避免把虚拟屏锁到一个瞎猜的值上
 */
@Composable
private fun VirtualDisplayFrameRateCard(
    state: SettingsUiState,
    onIntent: (SettingsIntent) -> Unit,
) {
    val context = LocalContext.current
    val displays = remember(context) { context.getSystemService(DisplayManager::class.java) }
    var maximum by remember(displays) {
        mutableStateOf(displays.getDisplay(Display.DEFAULT_DISPLAY)?.refreshRate ?: 0f)
    }
    DisposableEffect(displays) {
        fun updateMaximum() {
            maximum = displays.getDisplay(Display.DEFAULT_DISPLAY)?.refreshRate ?: 0f
        }
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) = updateMaximum()
            override fun onDisplayRemoved(displayId: Int) = updateMaximum()
            override fun onDisplayChanged(displayId: Int) {
                if (displayId == Display.DEFAULT_DISPLAY) updateMaximum()
            }
        }
        displays.registerDisplayListener(listener, Handler(Looper.getMainLooper()))
        updateMaximum()
        onDispose { displays.unregisterDisplayListener(listener) }
    }
    val supported = Build.VERSION.SDK_INT >= AndroidVersions.API_34_ANDROID_14
    val available = maximum.isFinite() && maximum > 1f
    val upper = if (available) maximum else 60f
    val savedRate = state.virtualDisplayRefreshRate
    var selected by remember(savedRate, upper) {
        mutableStateOf(if (savedRate == 0f) upper else savedRate.coerceIn(1f, upper))
    }
    MaaCard(title = stringResource(R.string.settings_virtual_display_rate), collapsible = true) {
        if (supported) {
            MaaInfoRow(
                stringResource(R.string.settings_virtual_display_rate_requested),
                stringResource(R.string.settings_virtual_display_rate_value, selected),
            )
            Slider(
                value = selected,
                onValueChange = { selected = round(it).coerceIn(1f, upper) },
                onValueChangeFinished = {
                    // 最大档存 0：后续启动继续跟随主屏当时的刷新率
                    onIntent(SettingsIntent.SetVirtualDisplayRefreshRate(if (selected == upper) 0f else selected))
                },
                valueRange = 1f..upper,
                enabled = available,
                modifier = Modifier.fillMaxWidth(),
            )
            if (available) {
                MaaInfoRow(
                    stringResource(R.string.settings_virtual_display_rate_maximum),
                    stringResource(R.string.settings_virtual_display_rate_value, maximum),
                )
            }
            Text(
                text = stringResource(
                    if (available) R.string.settings_virtual_display_rate_hint
                    else R.string.settings_virtual_display_rate_unavailable,
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            Text(
                text = stringResource(R.string.settings_virtual_display_rate_unsupported),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ColumnScope.LanguageChoice(onIntent: (SettingsIntent) -> Unit) {
    // 事实来源在平台侧 per-app locale（AppLocales），不进 UserConfiguration；
    // 切换后 Activity 重建，本处在新组合中重新读取，无需观察流
    // 语言名按惯例保持本族语原文，不随界面语言翻译
    val options = listOf<Pair<String?, String>>(
        null to stringResource(R.string.settings_follow_system),
        "zh-CN" to "简体中文",
        "en" to "English",
    )
    // 选中态用本地 state 立即回显：切到效果相同的档位（如 跟随系统(中文) ↔ 简体中文）
    // 不触发 Activity 重建，重新读 AppLocales 的时机不会到来
    var selectedTag by remember {
        mutableStateOf(
            when (val tag = AppLocales.currentTag()) {
                null -> null
                else -> if (tag.startsWith("zh")) "zh-CN" else "en"
            },
        )
    }
    MaaSingleChoiceFlow(
        options = options,
        selected = selectedTag,
        // 重复点选当前档位不发 Intent：避免无意义的 Activity 重建闪屏
        onSelect = { tag ->
            if (tag != selectedTag) {
                selectedTag = tag
                onIntent(SettingsIntent.SetLanguage(tag))
            }
        },
    )
    Text(
        text = stringResource(R.string.settings_language_hint),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/**
 * 日志区：两个查看入口 + 两条导出 + 自动清理开关
 *
 * 前四项都是「离开这一页」，只有自动清理是就地开关；关闭走确认弹窗（占空间警告）
 */
@Composable
private fun LogCard(
    state: SettingsUiState,
    onIntent: (SettingsIntent) -> Unit,
    onOpenAppLog: () -> Unit,
    onOpenAlasLog: () -> Unit,
    onExportAlasLogs: () -> Unit,
    onExportLauncherLogs: () -> Unit,
) {
    var showDisableConfirm by remember { mutableStateOf(false) }
    MaaCard(title = stringResource(R.string.settings_section_log), collapsible = true) {
        MaaNavigationRow(
            label = stringResource(R.string.app_log_title),
            description = stringResource(R.string.settings_log_launcher_desc),
            onClick = onOpenAppLog,
        )
        MaaNavigationRow(
            label = stringResource(R.string.alas_log_title),
            description = stringResource(R.string.settings_log_alas_desc),
            onClick = onOpenAlasLog,
        )
        MaaNavigationRow(
            label = stringResource(R.string.log_export_alas_title),
            description = stringResource(R.string.settings_log_export_alas_desc),
            onClick = onExportAlasLogs,
        )
        MaaNavigationRow(
            label = stringResource(R.string.log_export_launcher_title),
            description = stringResource(R.string.settings_log_export_launcher_desc),
            onClick = onExportLauncherLogs,
        )
        // 开启直接落盘；关闭先弹确认：关掉之后过期日志只增不减
        MaaLabeledControlRow(
            label = stringResource(R.string.settings_auto_clean_logs),
            trailing = {
                MaaSwitch(
                    checked = state.autoCleanLogs,
                    onCheckedChange = { enabled ->
                        if (enabled) onIntent(SettingsIntent.SetAutoCleanLogs(true))
                        else showDisableConfirm = true
                    },
                )
            },
        )
        Text(
            text = stringResource(R.string.settings_auto_clean_logs_desc),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
    if (showDisableConfirm) {
        AlertDialog(
            onDismissRequest = { showDisableConfirm = false },
            title = { Text(stringResource(R.string.dialog_disable_auto_clean_title)) },
            text = { Text(stringResource(R.string.dialog_disable_auto_clean_message)) },
            confirmButton = {
                TextButton(onClick = {
                    showDisableConfirm = false
                    onIntent(SettingsIntent.SetAutoCleanLogs(false))
                }) { Text(stringResource(R.string.dialog_confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { showDisableConfirm = false }) {
                    Text(stringResource(R.string.dialog_cancel))
                }
            },
        )
    }
}

/**
 * 启动模式（特权后端）：「跑起来之前得先定」的环境选项（对齐 MaaMeow 的「其他设置」）
 */
@Composable
private fun OtherCard(state: SettingsUiState, onIntent: (SettingsIntent) -> Unit) {
    MaaCard(title = stringResource(R.string.settings_section_other), collapsible = true) {
        MaaFieldLabel(stringResource(R.string.permission_backend))
        MaaSingleChoiceFlow(
            // 对齐 MaaMeow：只列后端名，不展示「可用/不可用」——选哪个都行，可用性交给连接流程判
            options = RemoteBackend.entries.map { it to it.display },
            selected = state.remoteAccess.configuredBackend,
            onSelect = { onIntent(SettingsIntent.SetBackend(it)) },
        )
    }
}

@Composable
private fun AboutCard() {
    MaaCard(title = stringResource(R.string.settings_about), collapsible = true) {
        MaaInfoRow(stringResource(R.string.settings_version), BuildConfig.VERSION_NAME)
        MaaInfoRow(stringResource(R.string.settings_build), BuildConfig.VERSION_CODE.toString())
    }
}
