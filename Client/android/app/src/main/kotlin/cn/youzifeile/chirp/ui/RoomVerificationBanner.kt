package cn.youzifeile.chirp.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import cn.youzifeile.chirp.R
import cn.youzifeile.chirp.data.base64Bytes
import cn.youzifeile.chirp.data.sha256
import cn.youzifeile.chirp.media.GroupMember
import cn.youzifeile.chirp.media.RoomTrustView
import java.text.Collator

internal fun RoomTrustView.verificationName(peer: GroupMember): String {
    if (peers.none { it.identity != peer.identity && it.name == peer.name }) return peer.name
    val suffix = peer.binding?.device?.leaf?.let { sha256(it.base64Bytes(32)).toHexString().takeLast(8) }
        ?: peer.identity.takeLast(8)
    return "${peer.name} · $suffix"
}

@Composable
internal fun RoomVerificationBanner(view: RoomTrustView, prepare: (GroupMember) -> Unit) {
    val locale = LocalConfiguration.current.locales[0]
    val targets = remember(view.peers, view.trusted, locale) {
        view.peers.filterNot { it.identity in view.trusted }
            .sortedWith(compareBy(Collator.getInstance(locale)) { peer: GroupMember -> peer.name })
    }
    val colors = MaterialTheme.colorScheme
    val ink = colors.onErrorContainer
    val compact = compactWindowHeight()
    Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = if (compact) 4.dp else 8.dp),
        contentAlignment = Alignment.TopCenter) {
        Surface(Modifier.widthIn(max = 640.dp).fillMaxWidth(), shape = MaterialTheme.shapes.large,
            color = colors.errorContainer, contentColor = ink, shadowElevation = 3.dp,
            border = BorderStroke(1.dp, ink.copy(alpha = .32f))) {
            BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = if (compact) 6.dp else 12.dp)) {
                val summary: @Composable (Modifier) -> Unit = { modifier ->
                    Row(modifier, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Surface(shape = MaterialTheme.shapes.medium, color = colors.error, contentColor = colors.onError) {
                            Glyph(R.drawable.ic_notice, Modifier.padding(7.dp).size(20.dp))
                        }
                        Column(Modifier.weight(1f).semantics { liveRegion = LiveRegionMode.Polite },
                            verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(stringResource(R.string.room_verification_paused), Modifier.semantics { heading() },
                                style = MaterialTheme.typography.titleMedium)
                            Text(when (targets.size) {
                                0 -> stringResource(R.string.verify_wait_others)
                                1 -> stringResource(R.string.trust_resume_help)
                                else -> pluralStringResource(R.plurals.room_verification_choose_member, targets.size, targets.size)
                            }, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
                val actions: @Composable (Modifier) -> Unit = { modifier ->
                    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
                        LazyRow(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(targets, key = { it.identity }) { peer ->
                                val name = view.verificationName(peer)
                                OutlinedButton(onClick = { prepare(peer) }, modifier = Modifier.widthIn(max = 280.dp),
                                    colors = ButtonDefaults.outlinedButtonColors(contentColor = ink),
                                    border = BorderStroke(1.dp, ink.copy(alpha = .55f))) {
                                    Glyph(R.drawable.ic_key, Modifier.size(16.dp),
                                        label = if (targets.size > 1) stringResource(R.string.verify_identity) else null)
                                    Spacer(Modifier.width(6.dp))
                                    Text(if (targets.size == 1) stringResource(R.string.trust_target, name) else name,
                                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                        if (targets.size > 1) {
                            var menu by remember { mutableStateOf(false) }
                            Box {
                                IconButton({ menu = true }) {
                                    Glyph(R.drawable.ic_more, label = stringResource(R.string.choose_verification_device))
                                }
                                DropdownMenu(menu, onDismissRequest = { menu = false }) {
                                    targets.forEach { peer ->
                                        DropdownMenuItem(text = { Text(view.verificationName(peer)) }, onClick = {
                                            menu = false
                                            prepare(peer)
                                        })
                                    }
                                }
                            }
                        }
                    }
                }
                if (compact && maxWidth >= 480.dp && targets.isNotEmpty()) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        summary(Modifier.weight(1f))
                        actions(Modifier.weight(.8f))
                    }
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        summary(Modifier.fillMaxWidth())
                        if (targets.isNotEmpty()) actions(Modifier.fillMaxWidth())
                    }
                }
            }
        }
    }
}
