package cc.seeed.voice

import android.app.Activity
import android.content.Intent
import com.linusu.flutter_web_auth_2.FlutterWebAuth2Plugin

/**
 * Handles `sensecraftvoice://oauth-callback` after GitHub OAuth.
 *
 * The stock [com.linusu.flutter_web_auth_2.CallbackActivity] only relaunches
 * [AuthenticationManagementActivity], so on Huawei/Honor system browsers the user
 * stays on the browser tab even though login already completed. We finish the
 * pending [FlutterWebAuth2.authenticate] call and explicitly open [MainActivity].
 */
class GithubOAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)

        val url = intent?.data
        val scheme = url?.scheme
        if (scheme != null) {
            FlutterWebAuth2Plugin.callbacks.remove(scheme)?.success(url.toString())
        }

        val main = Intent(this, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        startActivity(main)
        finish()
    }
}
