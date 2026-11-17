package com.yingyu.app

import android.app.Activity
import android.content.Context
import android.provider.Settings
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class TextInputBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "duanju/text_input")
    private val keyboard =
        activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
    private var input: HiddenInput? = null
    private var editing = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    result.success(
                        start(
                            call.argument<String>("text").orEmpty(),
                            call.argument<Boolean>("search") != false,
                            call.argument<Boolean>("password") == true,
                            call.argument<Boolean>("url") == true,
                            call.argument<Int>("maxLength"),
                        )
                    )
                }
                "stop" -> {
                    finish(false)
                    result.success(null)
                }
                "switch" -> {
                    showPicker()
                    result.success(null)
                }
                "ime" -> result.success(imeInfo())
                "active" -> result.success(keyboard.isActive)
                else -> result.notImplemented()
            }
        }
    }

    private fun view(): HiddenInput = input ?: HiddenInput(activity).also { view ->
        view.alpha = 0f
        view.background = null
        view.isCursorVisible = false
        view.isSingleLine = true
        view.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                if (editing) channel.invokeMethod("changed", s?.toString().orEmpty())
            }
        })
        view.setOnEditorActionListener { _, action, _ ->
            val submit = action == EditorInfo.IME_ACTION_SEARCH ||
                action == EditorInfo.IME_ACTION_DONE ||
                action == EditorInfo.IME_ACTION_GO
            if (submit) finish(true)
            submit
        }
        // 部分输入法（尤其第三方）不发 editor action，而是发回车键
        view.setOnKeyListener { _, keyCode, event ->
            if (event.action != KeyEvent.ACTION_UP) return@setOnKeyListener false
            when (keyCode) {
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                KeyEvent.KEYCODE_DPAD_CENTER -> {
                    finish(true)
                    true
                }
                else -> false
            }
        }
        view.setOnFocusChangeListener { _, focused ->
            if (focused || !editing) return@setOnFocusChangeListener
            // 第三方输入法的浮窗、语音面板会短暂抢焦点，稍等再判断，避免误关
            view.postDelayed({
                if (editing && !view.hasFocus() && !keyboard.isActive) finish(false)
            }, 320L)
        }
        view.onBack = { finish(false) }
        // 放在屏幕底部，让候选栏贴着输入法面板，而不是飘到左上角
        val params = FrameLayout.LayoutParams(1, 1).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
        }
        activity.addContentView(view, params)
        input = view
    }

    private fun start(
        text: String,
        search: Boolean,
        password: Boolean,
        url: Boolean,
        maxLength: Int?,
    ): Boolean {
        val view = view()
        editing = false
        view.inputType = InputType.TYPE_CLASS_TEXT or when {
            password -> InputType.TYPE_TEXT_VARIATION_PASSWORD
            url -> InputType.TYPE_TEXT_VARIATION_URI
            else -> 0
        }
        view.imeOptions = (if (search) EditorInfo.IME_ACTION_SEARCH else EditorInfo.IME_ACTION_DONE) or
            EditorInfo.IME_FLAG_NO_FULLSCREEN
        view.filters = maxLength?.let { arrayOf(InputFilter.LengthFilter(it)) } ?: emptyArray()
        view.setText(text)
        view.setSelection(text.length)
        editing = true
        view.requestFocus()
        // 视图刚挂上去时 showSoftInput 常常失效，等布局完成再弹，失败就重试
        view.post { showIme(view, 0) }
        return hasIme()
    }

    private fun showIme(view: EditText, attempt: Int) {
        if (!editing || attempt >= 6) return
        if (attempt == 4) {
            // 前几次都被忽略时强制切换一次，兼容个别只认 toggleSoftInput 的输入法
            keyboard.toggleSoftInput(InputMethodManager.SHOW_FORCED, 0)
        } else {
            keyboard.showSoftInput(view, if (attempt == 0) InputMethodManager.SHOW_IMPLICIT else 0)
        }
        view.postDelayed({
            if (editing && !keyboard.isActive) showIme(view, attempt + 1)
        }, 150L)
    }

    private fun hasIme(): Boolean = runCatching {
        keyboard.enabledInputMethodList.isNotEmpty()
    }.getOrDefault(false)

    private fun showPicker() {
        runCatching { keyboard.showInputMethodPicker() }
    }

    private fun imeInfo(): Map<String, Any> {
        val current = runCatching {
            Settings.Secure.getString(activity.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        }.getOrNull().orEmpty()
        val enabled: List<InputMethodInfo> = runCatching {
            keyboard.enabledInputMethodList
        }.getOrDefault(emptyList())
        val all: List<InputMethodInfo> = runCatching {
            keyboard.inputMethodList
        }.getOrDefault(emptyList())
        val info = enabled.firstOrNull { it.id == current } ?: all.firstOrNull { it.id == current }
        val label = runCatching {
            info?.loadLabel(activity.packageManager)?.toString().orEmpty()
        }.getOrDefault("")
        val thirdParty = enabled.any { ime ->
            val pkg = ime.packageName.orEmpty()
            ime.id != current && !pkg.startsWith("com.android") && !pkg.startsWith("com.google")
        }
        return mapOf(
            "id" to current,
            "label" to label,
            "enabled" to enabled.size,
            "available" to all.size,
            "thirdParty" to thirdParty,
        )
    }

    private fun finish(submit: Boolean) {
        if (!editing) return
        editing = false
        val view = input ?: return
        keyboard.hideSoftInputFromWindow(view.windowToken, 0)
        channel.invokeMethod("done", mapOf("text" to view.text.toString(), "submit" to submit))
        activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)?.requestFocus()
    }

    fun dispose() {
        finish(false)
        channel.setMethodCallHandler(null)
        input?.let { (it.parent as? ViewGroup)?.removeView(it) }
        input = null
    }
}

private class HiddenInput(context: Context) : EditText(context) {
    var onBack: (() -> Unit)? = null

    override fun onKeyPreIme(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode != KeyEvent.KEYCODE_BACK) return super.onKeyPreIme(keyCode, event)
        if (event.action == KeyEvent.ACTION_UP) onBack?.invoke()
        return true
    }
}
