package cn.youzifeile.chirp.ui

import cn.youzifeile.chirp.data.LogEvent
import android.app.LocaleManager
import android.content.Context
import android.os.LocaleList
import androidx.activity.ComponentActivity
import androidx.core.content.edit
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.ui.Modifier
import androidx.compose.runtime.*
import androidx.compose.ui.res.stringResource
import cn.youzifeile.chirp.R

internal object AppLanguage {
    fun initialize(context: Context) {
        val prefs = context.getSharedPreferences("language-initialization", Context.MODE_PRIVATE)
        if (prefs.contains("initialized")) return
        val info = context.packageManager.getPackageInfo(context.packageName, android.content.pm.PackageManager.PackageInfoFlags.of(0))
        prefs.edit { putBoolean("initialized", true) }
        if (selected(context).isEmpty() && info.firstInstallTime == info.lastUpdateTime) {
            context.getSystemService(LocaleManager::class.java).applicationLocales = LocaleList.forLanguageTags("zh-CN")
        }
    }

    fun selected(context: Context): String =
        context.getSystemService(LocaleManager::class.java).applicationLocales.toLanguageTags()
    fun choose(activity: ComponentActivity, tag: String) {
        if (selected(activity) == tag) return
        LogEvent.changeLanguage.record()
        activity.getSystemService(LocaleManager::class.java).applicationLocales = LocaleList.forLanguageTags(tag)
    }
}

@Composable
internal fun LanguageSetting(activity: ComponentActivity) {
    var open by remember { mutableStateOf(false) }
    val current = AppLanguage.selected(activity)
    val choices = listOf("" to stringResource(R.string.language_system), "zh-CN" to "简体中文", "en" to "English")
    SettingRow(R.drawable.ic_language, stringResource(R.string.language),
        supporting = choices.firstOrNull { it.first == current }?.second ?: current, onClick = { open = true })
    if (open) ChirpDialog(icon = R.drawable.ic_language, onDismissRequest = { open = false }, title = { Text(stringResource(R.string.language)) },
        text = { Column(Modifier.selectableGroup()) {
            choices.forEach { (tag, label) ->
                RadioSetting(label, current == tag, onSelect = { open = false; AppLanguage.choose(activity, tag) })
            }
        } }, confirmButton = { TextButton({ open = false }) { Text(stringResource(R.string.cancel)) } })
}
