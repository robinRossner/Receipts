package com.robinrossner.receipts.ui.settings

/** The pure rules of the Settings screen (kept out of the composable so they can be unit-tested). */
object SettingsLogic {
    const val SAVED_NOTE = "Saved. Syncing…"

    private const val URL_PROBLEM = "Not a valid address. Use https://…"
    private const val URL_PROBLEM_DEBUG = "Not a valid address. Use https://… (plain http:// works for the emulator host 10.0.2.2 and localhost in debug builds only)."

    /** Shown live under the fields when the address is non-empty but not usable. */
    fun urlProblem(url: String, valid: Boolean, debugBuild: Boolean): String? =
        if (url.isNotBlank() && !valid) (if (debugBuild) URL_PROBLEM_DEBUG else URL_PROBLEM) else null

    /** Save and Test connection need a usable address and a token (stored or typed). */
    fun canSave(urlValid: Boolean, hasStoredToken: Boolean, typedToken: String): Boolean =
        urlValid && (hasStoredToken || typedToken.isNotBlank())

    fun tokenPlaceholder(hasStoredToken: Boolean): String = if (hasStoredToken) "Saved in Keystore" else "Paste the token"

    /** The "Saved. Syncing…" note disappears once a sync has finished; any other note stays. */
    fun clearSavedNote(note: String?, syncIdle: Boolean): Boolean = syncIdle && note == SAVED_NOTE

    fun photosFooter(cacheLimit: String): String =
        "This phone keeps up to $cacheLimit of receipt photos, oldest dropped first. The permanent photo archive is on your laptop: this phone never archives photos or releases the server's copy."

    fun changeCount(n: Int): String = "$n change(s)"
    fun recordCount(n: Int): String = "$n record(s)"
}
