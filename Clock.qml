import QtQuick

// Production clock adapter. It owns elapsed time and timer mechanics while
// RouterService decides which reader cadence is currently needed.
Item {
  id: root

  // RouterService supplies all timing policy at composition.
  property int healthIntervalMs: 0
  property int dataIntervalMs: 0
  property int lifecycleDelayMs: 0
  property bool healthCadenceActive: false
  property bool dataCadenceActive: false

  signal healthCadence()
  signal dataCadence()
  signal lifecycleDelay()

  function now() {
    return Date.now()
  }

  function scheduleLifecycleDelay() {
    lifecycleTimer.restart()
  }

  onHealthIntervalMsChanged: if (healthTimer.running) healthTimer.restart()
  onDataIntervalMsChanged: if (dataTimer.running) dataTimer.restart()

  Timer {
    id: healthTimer
    interval: root.healthIntervalMs
    running: root.healthCadenceActive
    triggeredOnStart: true
    repeat: true
    onTriggered: root.healthCadence()
  }

  Timer {
    id: dataTimer
    interval: root.dataIntervalMs
    running: root.dataCadenceActive
    repeat: true
    onTriggered: root.dataCadence()
  }

  Timer {
    id: lifecycleTimer
    interval: root.lifecycleDelayMs
    repeat: false
    onTriggered: root.lifecycleDelay()
  }
}
