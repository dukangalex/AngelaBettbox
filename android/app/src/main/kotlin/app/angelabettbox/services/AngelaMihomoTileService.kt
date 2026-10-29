package app.angelabettbox.services

import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi
import app.angelabettbox.GlobalState
import app.angelabettbox.RunState
import app.angelabettbox.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

@RequiresApi(Build.VERSION_CODES.N)
class AngelaMihomoTileService : TileService() {

    companion object {
        @Volatile
        private var activeInstance: AngelaMihomoTileService? = null

        fun refreshActive() {
            activeInstance?.updateTile(GlobalState.currentRunState)
        }
    }

    private var scope: CoroutineScope? = null

    private fun updateTile(runState: RunState) {
        qsTile?.apply {
            state = when (runState) {
                RunState.START -> Tile.STATE_ACTIVE
                RunState.PENDING -> Tile.STATE_UNAVAILABLE
                RunState.STOP -> Tile.STATE_INACTIVE
            }
            if (GlobalState.isSpeedNotificationEnabled && GlobalState.currentProfileName.isNotEmpty()) {
                label = GlobalState.currentProfileName
            } else {
                label = getString(R.string.angela_mihomo)
            }
            updateTile()
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        activeInstance = this
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        GlobalState.syncStatus()
        scope?.launch {
            GlobalState.runState.collect { updateTile(it) }
        }
    }

    override fun onStopListening() {
        if (activeInstance === this) {
            activeInstance = null
        }
        scope?.cancel()
        scope = null
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE && isLocked) {
            unlockAndRun { GlobalState.handleToggle() }
        } else {
            GlobalState.handleToggle()
        }
    }

    override fun onDestroy() {
        if (activeInstance === this) {
            activeInstance = null
        }
        scope?.cancel()
        scope = null
        super.onDestroy()
    }
}