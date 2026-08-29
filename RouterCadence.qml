import QtQuick

// Quickshell-free reader cadence policy. RouterService supplies its demand and
// receives semantic events; the clock adapter owns timers and current time.
Item {
  id: root

  required property var clock
  property int healthIntervalMs: 0
  property int dataIntervalMs: 0
  property int lifecycleDelayMs: 0
  property int proofIntervalMs: 0
  property bool healthCadenceActive: false
  property bool dataCadenceActive: false
  property bool proofCadenceActive: false
  property bool recoveryPending: false

  signal healthCadenceDue()
  signal dataCadenceDue()
  signal proofCadenceDue()
  signal recoveryDelayDue()

  function scheduleRecovery() {
    root.recoveryPending = true
    root.clock.scheduleLifecycleDelay()
  }

  Binding {
    target: root.clock
    property: "healthIntervalMs"
    value: root.healthIntervalMs
  }

  Binding {
    target: root.clock
    property: "dataIntervalMs"
    value: root.dataIntervalMs
  }

  Binding {
    target: root.clock
    property: "lifecycleDelayMs"
    value: root.lifecycleDelayMs
  }

  Binding {
    target: root.clock
    property: "proofIntervalMs"
    value: root.proofIntervalMs
  }

  Binding {
    target: root.clock
    property: "healthCadenceActive"
    value: root.healthCadenceActive
  }

  Binding {
    target: root.clock
    property: "dataCadenceActive"
    value: root.dataCadenceActive
  }

  Binding {
    target: root.clock
    property: "proofCadenceActive"
    value: root.proofCadenceActive
  }

  Connections {
    target: root.clock

    function onHealthCadence() {
      root.healthCadenceDue()
    }

    function onDataCadence() {
      root.dataCadenceDue()
    }

    function onProofCadence() {
      root.proofCadenceDue()
    }

    function onLifecycleDelay() {
      if (!root.recoveryPending) return
      root.recoveryPending = false
      root.recoveryDelayDue()
    }
  }
}
