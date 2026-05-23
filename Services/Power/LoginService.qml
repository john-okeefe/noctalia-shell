pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Compositor
import qs.Services.UI

Singleton {
  id: root

  readonly property bool available: _probed && _logindFound && _dbusMonitorFound
  readonly property bool active: _active

  property bool _probed: false
  property bool _logindFound: false
  property bool _dbusMonitorFound: false
  property bool _active: false
  property var _monitorProcess: null
  property int _restartAttempts: 0
  property bool _signalReceived: false

  readonly property int _maxRestartAttempts: 3

  signal prepareForSleep(bool sleeping)

  function init() {
    Logger.i("LoginService", "Probing for logind and dbus-monitor...");
    _probeLogind();
  }

  function _probeLogind() {
    var proc = Qt.createQmlObject("
      import QtQuick
      import Quickshell.Io

      Process {
        command: [\"dbus-send\", \"--system\", \"--print-reply\", \"--dest=org.freedesktop.login1\",
                  \"/org/freedesktop/login1\", \"org.freedesktop.DBus.Introspectable.Introspect\"]
        running: false
        stdout: StdioCollector {}
        onExited: function(exitCode) {
          LoginService._onLogindProbe(exitCode, stdout.text);
          destroy();
        }
      }
    ", root, "LogindProbe");
    if (proc)
      proc.running = true;
    else
      _onLogindProbe(1, "");
  }

  function _onLogindProbe(exitCode, output) {
    _logindFound = exitCode === 0 && output.length > 0;
    if (_logindFound)
      Logger.i("LoginService", "logind found on system bus");
    else
      Logger.w("LoginService", "logind not available on system bus");

    _probeDbusMonitor();
  }

  function _probeDbusMonitor() {
    var proc = Qt.createQmlObject("
      import QtQuick
      import Quickshell.Io

      Process {
        command: [\"which\", \"dbus-monitor\"]
        running: false
        stdout: StdioCollector {}
        onExited: function(exitCode) {
          LoginService._onDbusMonitorProbe(exitCode);
          destroy();
        }
      }
    ", root, "DbusMonitorProbe");
    if (proc)
      proc.running = true;
    else
      _onDbusMonitorProbe(1);
  }

  function _onDbusMonitorProbe(exitCode) {
    _dbusMonitorFound = exitCode === 0;
    _probed = true;

    if (_dbusMonitorFound) {
      Logger.i("LoginService", "dbus-monitor available");
    } else {
      Logger.w("LoginService", "dbus-monitor not found");
    }

    if (available) {
      Logger.i("LoginService", "All dependencies met, starting monitor");
      _startMonitor();
    } else {
      Logger.i("LoginService", "logind/dbus-monitor not available — using Time.resumed fallback only");
    }
  }

  function _startMonitor() {
    if (!available) {
      Logger.w("LoginService", "Cannot start monitor — dependencies not met");
      return;
    }
    if (_monitorProcess) {
      Logger.w("LoginService", "Monitor already running");
      return;
    }

    _signalReceived = false;

    _monitorProcess = Qt.createQmlObject("
      import QtQuick
      import Quickshell.Io

      Process {
        command: [\"dbus-monitor\", \"--system\", \"path='/org/freedesktop/login1',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'\"]
        running: false
        stdout: SplitParser {
          onRead: function(data) {
            LoginService._parseLine(data);
          }
        }
        onExited: function(exitCode, exitStatus) {
          LoginService._onMonitorExited(exitCode, exitStatus);
        }
      }
    ", root, "LoginMonitorProcess");

    if (_monitorProcess) {
      _monitorProcess.running = true;
      _active = true;
      _restartAttempts = 0;
      Logger.i("LoginService", "D-Bus monitor started (listening for PrepareForSleep)");
    } else {
      Logger.e("LoginService", "Failed to create monitor process");
      _active = false;
    }
  }

  property string _signalBuffer: ""

  function _parseLine(line) {
    var trimmed = line.trim();

    if (trimmed.indexOf("member=PrepareForSleep") !== -1) {
      _signalBuffer = "pending";
      return;
    }

    if (_signalBuffer === "pending" && trimmed.indexOf("boolean") !== -1) {
      var sleeping = trimmed.indexOf("true") !== -1;
      _signalBuffer = "";
      _signalReceived = true;
      _restartAttempts = 0;
      _handlePrepareForSleep(sleeping);
      return;
    }

    if (_signalBuffer === "pending" && trimmed.length === 0) {
      _signalBuffer = "";
    }
  }

  function _handlePrepareForSleep(sleeping) {
    Logger.i("LoginService", "PrepareForSleep: " + (sleeping ? "suspending" : "resuming"));
    prepareForSleep(sleeping);

    if (!Settings.data.general.lockOnSuspend)
      return;

    if (PanelService.lockScreen) {
      if (sleeping) {
        if (!PanelService.lockScreen.active) {
          Logger.i("LoginService", "Locking screen before suspend");
          PanelService.lockScreen.active = true;
        }
      } else {
        if (!PanelService.lockScreen.active) {
          Logger.i("LoginService", "Locking screen on resume");
          PanelService.lockScreen._lockOnResume = true;
          PanelService.lockScreen.active = true;
        } else {
          PanelService.lockScreen.graceAllowed = false;
          PanelService.lockScreen.lockedAt = 0;
        }
      }
    }
  }

  function _onMonitorExited(exitCode, exitStatus) {
    _active = false;
    _cleanupMonitor();

    if (!_signalReceived && exitCode !== 0) {
      _restartAttempts++;
      if (_restartAttempts >= _maxRestartAttempts) {
        Logger.w("LoginService", "Monitor failed " + _restartAttempts + " times without receiving signals — giving up (Time.resumed fallback active)");
        return;
      }
    } else {
      _restartAttempts = 0;
    }

    Logger.i("LoginService", "Monitor exited (code " + exitCode + "), restarting in 5s (attempt " + (_restartAttempts + 1) + "/" + _maxRestartAttempts + ")");
    restartTimer.start();
  }

  function _cleanupMonitor() {
    if (_monitorProcess) {
      _monitorProcess.running = false;
      _monitorProcess.destroy();
      _monitorProcess = null;
    }
    _active = false;
  }

  Timer {
    id: restartTimer
    interval: 5000
    repeat: false
    onTriggered: {
      if (root.available)
        root._startMonitor();
    }
  }

  Component.onDestruction: {
    restartTimer.stop();
    _cleanupMonitor();
  }
}
