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
  readonly property bool inhibitorActive: _inhibitProcess !== null

  property bool _probed: false
  property bool _logindFound: false
  property bool _dbusMonitorFound: false
  property bool _active: false
  property var _monitorProcess: null
  property var _inhibitProcess: null
  property int _restartAttempts: 0
  property bool _signalReceived: false
  property string _inhibitBinary: ""
  property int _lockConfirmCount: 0

  readonly property int _maxRestartAttempts: 3
  readonly property int _maxLockConfirmAttempts: 30

  signal prepareForSleep(bool sleeping)

  function init() {
    Logger.i("LoginService", "Probing for logind and dbus-monitor...");
    _probeInhibitBinary();
  }

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
    if (path.length > 0) {
      _inhibitBinary = path;
      Logger.i("LoginService", "Inhibit binary found: " + path);
    } else {
      _inhibitBinary = "";
      Logger.w("LoginService", "No inhibit binary found (elogind-inhibit / systemd-inhibit)");
    }
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
      Logger.i("LoginService", "All dependencies met, starting monitor and delay inhibitor");
      _startMonitor();
      _startInhibitor();
    } else {
      Logger.i("LoginService", "logind/dbus-monitor not available — using Time.resumed fallback only");
    }
  }

  function _startInhibitor() {
    if (_inhibitBinary.length === 0) {
      Logger.w("LoginService", "Cannot start delay inhibitor — no inhibit binary");
      return;
    }
    if (_inhibitProcess) {
      Logger.d("LoginService", "Delay inhibitor already running");
      return;
    }

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
      Logger.i("LoginService", "Sleep delay inhibitor active");
    } else {
      Logger.e("LoginService", "Failed to create delay inhibitor process");
    }
  }

  function _releaseInhibitor() {
    if (_inhibitProcess) {
      _inhibitProcess.signal(15);
      _inhibitProcess.running = false;
      _inhibitProcess.destroy();
      _inhibitProcess = null;
      Logger.i("LoginService", "Sleep delay inhibitor released — system may now suspend");
    }
  }

  function _onInhibitorExited(exitCode) {
    if (_inhibitProcess) {
      _inhibitProcess.destroy();
      _inhibitProcess = null;
    }
    if (!_suspending) {
      Logger.w("LoginService", "Delay inhibitor exited unexpectedly (" + exitCode + "), restarting in 5s");
      inhibitorRestartTimer.start();
    }
  }

  property bool _suspending: false

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
        _suspending = true;
        if (!PanelService.lockScreen.active) {
          Logger.i("LoginService", "Locking screen before suspend (inhibitor holding)");
          PanelService.lockScreen.active = true;
          _lockConfirmCount = 0;
          lockConfirmTimer.start();
        } else {
          Logger.i("LoginService", "Screen already locked, releasing inhibitor");
          _releaseInhibitor();
        }
      } else {
        _suspending = false;
        if (!PanelService.lockScreen.active) {
          Logger.i("LoginService", "Locking screen on resume");
          PanelService.lockScreen._lockOnResume = true;
          PanelService.lockScreen.active = true;
        } else {
          PanelService.lockScreen.graceAllowed = false;
          PanelService.lockScreen.lockedAt = 0;
        }
        inhibitorRestartTimer.start();
      }
    }
  }

  Timer {
    id: lockConfirmTimer
    interval: 100
    repeat: true
    running: false

    onTriggered: {
      root._lockConfirmCount++;

      if (PanelService.lockScreen && PanelService.lockScreen.active && PanelService.lockScreen.item) {
        Logger.i("LoginService", "Lock screen confirmed active, releasing inhibitor");
        stop();
        root._releaseInhibitor();
        return;
      }

      if (root._lockConfirmCount >= root._maxLockConfirmAttempts) {
        Logger.w("LoginService", "Lock screen not confirmed after 3s, releasing inhibitor anyway");
        stop();
        root._releaseInhibitor();
      }
    }
  }

  Timer {
    id: inhibitorRestartTimer
    interval: 5000
    repeat: false
    onTriggered: {
      if (root.available && !root._suspending)
        root._startInhibitor();
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
    lockConfirmTimer.stop();
    inhibitorRestartTimer.stop();
    _releaseInhibitor();
    _cleanupMonitor();
  }
}
