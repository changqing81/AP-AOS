package com.aliothmoon.maafw.ui.alas

import android.webkit.WebView

/**
 * ALAS WebUI 的 WebView 注册处：App 整体退后台时统一暂停，回前台恢复
 *
 * 只挂在 MainActivity 的 onStart/onStop 上：切 tab 不暂停（pager 三页常驻
 * 是 v0.1.5 修黑屏的决策，切页时 pywebio 不该断线）
 * （采纳自 Shinarin/ALAS-AOS f6eb30f9，2026-09-25）
 */
object AlasWebViewHolder {

    private val webViews = mutableSetOf<WebView>()

    fun register(webView: WebView) {
        webViews += webView
    }

    fun unregister(webView: WebView) {
        webViews -= webView
    }

    /** pauseTimers 是 WebView 全局的；onPause 才是逐实例的，两个都调才算真停 */
    fun pauseAll() {
        webViews.forEach {
            it.onPause()
            it.pauseTimers()
        }
    }

    fun resumeAll() {
        webViews.forEach {
            it.onResume()
            it.resumeTimers()
        }
    }
}
