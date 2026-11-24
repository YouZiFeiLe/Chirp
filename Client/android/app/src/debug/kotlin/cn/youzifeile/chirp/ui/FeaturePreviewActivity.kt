package cn.youzifeile.chirp.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import cn.youzifeile.chirp.ChirpApplication
import cn.youzifeile.chirp.data.*
import cn.youzifeile.chirp.media.*

/** Debug-only fixture. No server discovery, authentication, room connection or automatic capture. */
class FeaturePreviewActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val model = viewModel { MainViewModel(application as ChirpApplication, restoreOnStart = false) }
            val state by model.state.collectAsStateWithLifecycle()
            val call by model.calls.state.collectAsStateWithLifecycle()
            var screen by rememberSaveable { mutableStateOf(intent.getStringExtra("screen") ?: "audio") }
            val profiles = remember {
                listOf(Profile("alex", "Alex", 1), Profile("youzi", "小柚", 1), Profile("lin", "阿林", 1))
            }
            val directory = remember {
                val people = profiles.map { DirectoryMember(it.id, it.name) }
                val lobby = RoomInfo("lobby", "", false, true, GROUP_PROTOCOL, 0, "available", people)
                Directory("sample", 1UL, listOf(lobby,
                    lobby.copy(id = "studio", name = "声音工作室", isDefault = false, participants = people.takeLast(2),
                        description = "周五晚八点听歌 🎵\n欢迎带上朋友。"),
                    lobby.copy(id = "night", name = "深夜放映室", isDefault = false, passwordRequired = true, maxParticipants = 6,
                        participants = emptyList())), profiles)
            }
            val demo = state.copy(checking = false, account = profiles[1], directory = directory,
                identity = AccountView(synced = true, friends = profiles.filter { it != profiles[1] }.mapIndexed { index, profile ->
                    Friend(profile.id, base64(ByteArray(32) { (index + 1).toByte() }), profile.name)
                }))
            ChirpTheme {
                when (screen) {
                    "audio" -> AudioSettings(this@FeaturePreviewActivity, call, model) { screen = "rooms" }
                    "storage" -> StorageSettings(model) { screen = "rooms" }
                    "rooms" -> ChirpApp(this@FeaturePreviewActivity, demo, CallState(), model)
                    "room", "call", "empty" -> {
                        val room = if (screen == "empty") directory.rooms.last() else directory.rooms.first()
                        val previewCall = if (screen != "call") CallState() else CallState(
                            room = room, phase = CallPhase.Connected, entryID = "sample-entry", chatVisible = true,
                            members = listOf(RoomMember("alex.remote", "Alex", microphoneEnabled = true, listening = true, speaking = true),
                                RoomMember("youzi.sample-entry", "小柚", microphoneEnabled = false, listening = true),
                                RoomMember("lin.remote", "阿林", microphoneEnabled = false, listening = false)),
                            messages = listOf(ChatMessage("1", "Alex", "大家听得清吗？", false),
                                ChatMessage("2", "小柚", "听得清，一起聊聊吧。", true)))
                        RoomScreen(this@FeaturePreviewActivity, room, demo, previewCall, model, { screen = "rooms" },
                            { screen = "audio" })
                    }
                    else -> LanguageSetting(this@FeaturePreviewActivity)
                }
            }
        }
    }
}
