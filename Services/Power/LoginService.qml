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

  readonly property int _maxRestartAttempts: 3
  readonly property int _maxLockConfirmAttempts: 30

  signal prepareForSleep(bool sleeping)

  function init() {
    Logger.i("LoginService", "Probing for logind, dbus-monitor, and inhibit binary...");
    _probeInhibitBinary();
  }

  // --- Probing ---

  function _probeInhibitBinary() {
    var proc = Qt.createQmlObject("
      import QtQuick
      import Quickshell.Io

      Process {
        command: [\"sh\", \"-c\", \"which elogind-inhibit 2>/dev/null || which systemd-inhibit 2>/dev/null || echo ''\"]
        running: false
        stdout: StdioCollector {}
        onExited: function(exitCode) {
          LoginService._onInhibitBinaryProbe(stdout.text.trim());
          destroy();
        }
      }
    ", root, "InhibitBinaryProbe");
    if (proc)
      proc.running = true;
    else
      _onInhibitBinaryProbe("");
  }

  function _onInhibitBinaryProbe(path) {
    _inhibitBinary = path;
    if (path.length > 0)
      Logger.i("LoginService", "Inhibit binary: " + path);
    else
      Logger.w("LoginService", "No inhibit binary found");
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

    if (_dbusMonitorFound)
      Logger.i("LoginService", "dbus-monitor available");
    else
      Logger.w("LoginService", "dbus-monitor not found");

    if (available) {
      Logger.i("LoginService", "All dependencies met, starting monitor and persistent inhibitor");
      _startMonitor();
      _startInhibitor();
    } else {
      Logger.i("LoginService", "Dependencies not met — using Time.resumed fallback only");
    }
  }

  // --- Persistent delay inhibitor ---
  //
  // Matches hypridle's approach: take the delay lock at startup and hold it
  // persistently. When PrepareForSleep(true) fires, the inhibitor is ALREADY
  // active, so logind waits. We activate the lockscreen, poll until confirmed,
  // then release the inhibitor — suspend proceeds with lockscreen rendering.
  // On resume, retake the inhibitor for the next cycle.

  function _startInhibitor() {
    if (_inhibitBinary.length === 0 || _inhibitProcess)
      return;

    _inhibitProcess = Qt.createQmlObject("
      import QtQuick
      import Quickshell.Io

      Process {
        command: [\"" + _inhibitBinary + "\", \"--what=sleep\", \"--who=noctalia-shell\",
                  \"--why=Holding suspend until lockscreen is active\", \"--mode=delay\",
                  \"sleep\", \"infinity\"]
        running: false
        onExited: function(exitCode) {
          LoginService._onInhibitorExited(exitCode);
        }
      }
    ", root, "InhibitProcess");

    if (_inhibitProcess) {
      _inhibitProcess.running = true;
      Logger.i("LoginService", "Sleep delay inhibitor active (persistent)");
    }
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
      // Expected — we released it to allow suspend
      _inhibitorHolding = false;
    } else {
      // Unexpected exit — restart after delay
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
      Logger.i("LoginService", "D-Bus monitor started");
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
      // The persistent inhibitor is already holding the suspend.
      // Activate lockscreen, then release inhibitor once confirmed.
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
      // Resume: ensure locked, kill grace, retake inhibitor for next cycle
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
