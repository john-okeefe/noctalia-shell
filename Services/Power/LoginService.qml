pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Singleton {
  id: root

  readonly property bool available: _probed && _logindFound && _dbusMonitorFound && _inhibitBinary !== ""

  property bool _probed: false
  property bool _logindFound: false
  property bool _dbusMonitorFound: false
  property string _inhibitBinary: ""
  property bool _active: false
  property var _monitorProcess: null
  property var _inhibitProcess: null
  property int _restartAttempts: 0
  property bool _signalReceived: false
  property int _lockConfirmCount: 0
  property bool _inhibitorHolding: false
  property int _probePhase: 0

  readonly property int _maxRestartAttempts: 3
  readonly property int _maxLockConfirmAttempts: 30

  signal prepareForSleep(bool sleeping)

  function init() {
    Logger.i("LoginService", "Probing for logind, dbus-monitor, and inhibit binary...");
    _probePhase = 1;
    inhibitBinaryProbe.running = true;
  }

  // --- Probing (static Process blocks) ---

  Process {
    id: inhibitBinaryProbe
    command: ["sh", "-c", "which elogind-inhibit 2>/dev/null || which systemd-inhibit 2>/dev/null || echo ''"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text || "").trim();
        root._inhibitBinary = path;
        if (path.length > 0)
          Logger.i("LoginService", "Inhibit binary: " + path);
        else
          Logger.w("LoginService", "No inhibit binary found");
        root._probePhase = 2;
        logindProbe.running = true;
      }
    }
  }

  Process {
    id: logindProbe
    command: ["dbus-send", "--system", "--print-reply", "--dest=org.freedesktop.login1",
              "/org/freedesktop/login1", "org.freedesktop.DBus.Introspectable.Introspect"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var output = String(text || "");
        root._logindFound = output.length > 0;
        if (root._logindFound)
          Logger.i("LoginService", "logind found on system bus");
        else
          Logger.w("LoginService", "logind not available on system bus");
        root._probePhase = 3;
        dbusMonitorProbe.running = true;
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root._logindFound = false;
        Logger.w("LoginService", "logind probe failed (exit " + exitCode + ")");
      }
    }
  }

  Process {
    id: dbusMonitorProbe
    command: ["which", "dbus-monitor"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var output = String(text || "").trim();
        root._dbusMonitorFound = output.length > 0;
      }
    }
    onExited: function(exitCode) {
      root._dbusMonitorFound = exitCode === 0;
      root._probed = true;

      if (root._dbusMonitorFound)
        Logger.i("LoginService", "dbus-monitor available");
      else
        Logger.w("LoginService", "dbus-monitor not found");

      if (root.available) {
        Logger.i("LoginService", "All dependencies met, starting monitor and persistent inhibitor");
        root._startMonitor();
        root._startInhibitor();
      } else {
        Logger.i("LoginService", "Dependencies not met — using Time.resumed fallback only");
      }
    }
  }

  // --- Persistent delay inhibitor ---

  function _startInhibitor() {
    if (_inhibitBinary.length === 0 || _inhibitProcess)
      return;

    _inhibitProcess = Qt.createQmlObject("
      import QtQuick
      import Quickshell.Io

      Process {
        running: false
        onExited: function(exitCode) {
          root._onInhibitorExited(exitCode);
        }
      }
    ", root, "InhibitProcess");

    if (!_inhibitProcess) {
      Logger.e("LoginService", "Failed to create inhibitor process object");
      return;
    }

    _inhibitProcess.command = [_inhibitBinary, "--what=sleep", "--who=noctalia-shell",
                               "--why=Holding suspend until lockscreen is active", "--mode=delay",
                               "sleep", "infinity"];
    _inhibitProcess.running = true;
    Logger.i("LoginService", "Sleep delay inhibitor active (persistent)");
  }

  function _releaseInhibitor() {
    if (_inhibitProcess) {
      _inhibitProcess.signal(15);
      _inhibitProcess.destroy();
      _inhibitProcess = null;
      _inhibitorHolding = false;
      Logger.i("LoginService", "Sleep delay inhibitor released — suspend may proceed");
    }
  }

  function _onInhibitorExited(exitCode) {
    if (_inhibitProcess) {
      _inhibitProcess.destroy();
      _inhibitProcess = null;
    }

    if (_inhibitorHolding) {
      _inhibitorHolding = false;
    } else {
      Logger.w("LoginService", "Inhibitor exited unexpectedly (" + exitCode + "), restarting in 5s");
      inhibitorRestartTimer.start();
    }
  }

  // --- D-Bus monitor ---

  function _startMonitor() {
    if (!available || _monitorProcess)
      return;

    _signalReceived = false;

    _monitorProcess = Qt.createQmlObject("
      import QtQuick
      import Quickshell.Io

      Process {
        running: false
        stdout: SplitParser {
          onRead: function(data) {
            root._parseLine(data);
          }
        }
        onExited: function(exitCode, exitStatus) {
          root._onMonitorExited(exitCode, exitStatus);
        }
      }
    ", root, "LoginMonitorProcess");

    if (!_monitorProcess) {
      Logger.e("LoginService", "Failed to create monitor process object");
      return;
    }

    _monitorProcess.command = ["dbus-monitor", "--system", "path='/org/freedesktop/login1',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'"];
    _monitorProcess.running = true;
    _active = true;
    _restartAttempts = 0;
    Logger.i("LoginService", "D-Bus monitor started");
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

    if (_signalBuffer === "pending" && trimmed.length === 0)
      _signalBuffer = "";
  }

  // --- Core suspend/resume logic ---

  function _handlePrepareForSleep(sleeping) {
    Logger.i("LoginService", "PrepareForSleep: " + (sleeping ? "suspending" : "resuming"));
    prepareForSleep(sleeping);

    if (!Settings.data.general.lockOnSuspend)
      return;

    var lockScreen = PanelService.lockScreen;
    if (!lockScreen)
      return;

    if (sleeping) {
      _inhibitorHolding = true;

      if (lockScreen.active && lockScreen.item) {
        Logger.i("LoginService", "Screen already locked, releasing inhibitor");
        _releaseInhibitor();
      } else {
        Logger.i("LoginService", "Locking screen (inhibitor holding suspend)...");
        lockScreen._lockOnResume = false;
        lockScreen.active = true;
        _lockConfirmCount = 0;
        lockConfirmTimer.start();
      }
    } else {
      if (!lockScreen.active) {
        Logger.i("LoginService", "Locking screen on resume");
        lockScreen._lockOnResume = true;
        lockScreen.active = true;
      } else {
        lockScreen.graceAllowed = false;
        lockScreen.lockedAt = 0;
      }
      inhibitorRestartTimer.start();
    }
  }

  Timer {
    id: lockConfirmTimer
    interval: 100
    repeat: true
    running: false

    onTriggered: {
      root._lockConfirmCount++;

      var lockScreen = PanelService.lockScreen;
      if (lockScreen && lockScreen.active && lockScreen.item) {
        Logger.i("LoginService", "Lock screen confirmed active, releasing inhibitor");
        stop();
        root._releaseInhibitor();
        return;
      }

      if (root._lockConfirmCount >= root._maxLockConfirmAttempts) {
        Logger.w("LoginService", "Lock screen not confirmed after 3s, releasing inhibitor");
        stop();
        root._releaseInhibitor();
      }
    }
  }

  // --- Monitor lifecycle ---

  function _onMonitorExited(exitCode, exitStatus) {
    _active = false;
    _cleanupMonitor();

    if (!_signalReceived && exitCode !== 0) {
      _restartAttempts++;
      if (_restartAttempts >= _maxRestartAttempts) {
        Logger.w("LoginService", "Monitor failed " + _restartAttempts + " times — giving up (Time.resumed fallback active)");
        return;
      }
    } else {
      _restartAttempts = 0;
    }

    Logger.i("LoginService", "Monitor exited (code " + exitCode + "), restarting in 5s");
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

  Timer {
    id: inhibitorRestartTimer
    interval: 5000
    repeat: false
    onTriggered: {
      if (root.available)
        root._startInhibitor();
    }
  }

  Component.onDestruction: {
    restartTimer.stop();
    lockConfirmTimer.stop();
    inhibitorRestartTimer.stop();
    _releaseInhibitor();
    _cleanupMonitor();
  }
}
