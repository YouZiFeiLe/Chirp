package cn.youzifeile.chirp

import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.view.WindowManager
import android.view.inspector.WindowInspector
import androidx.core.view.isVisible

/** Recents can keep a live surface resumed. Cover the activity and its dialogs when focus leaves the task. */
internal class TaskPreview(private val decor: View, private val focusChanged: (Boolean) -> Unit) {
    private val watched = mutableSetOf<View>()
    private val hidden = mutableMapOf<View, View>()
    private val refresh = Runnable { update() }
    private val listener = ViewTreeObserver.OnWindowFocusChangeListener {
        update()
        // A dialog can be attaching or detaching during the focus transfer.
        decor.removeCallbacks(refresh)
        decor.post(refresh)
    }

    fun update() {
        val tokens = setOfNotNull((decor.layoutParams as? WindowManager.LayoutParams)?.token, decor.windowToken)
        val windows = WindowInspector.getGlobalWindowViews().filter {
            it === decor || (it.layoutParams as? WindowManager.LayoutParams)?.token in tokens
        }
        val focused = windows.any { it.hasWindowFocus() }
        for (view in windows) {
            if (watched.add(view)) view.viewTreeObserver.addOnWindowFocusChangeListener(listener)
            if (focused) hidden.remove(view)?.visibility = View.VISIBLE
            else if (view !in hidden) {
                val content = view.findViewById<View>(android.R.id.content) ?: (view as? ViewGroup)?.getChildAt(0) ?: continue
                if (content.isVisible) {
                    hidden[view] = content
                    content.visibility = View.INVISIBLE
                }
            }
        }
        for (view in watched - windows.toSet()) unwatch(view)
        focusChanged(focused)
    }

    private fun unwatch(view: View) {
        watched.remove(view)
        if (view.viewTreeObserver.isAlive) view.viewTreeObserver.removeOnWindowFocusChangeListener(listener)
        hidden.remove(view)?.visibility = View.VISIBLE
    }

    fun close() {
        decor.removeCallbacks(refresh)
        watched.toList().forEach(::unwatch)
    }
}
