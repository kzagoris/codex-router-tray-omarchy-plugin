import QtQuick
import qs.Commons
import qs.Ui
import "../logic/Catalog.js" as Catalog
import "../ui"

// MODELS view: every catalog model the target offers, grouped by provider,
// with one live toggle.
//
// A sub-switcher — not two stacked lists — chooses whether that toggle edits
// picker visibility or subagent eligibility, so a click can never land on the
// wrong setting (the failure the router's own tray documents in its source).
// Its labels carry both counts, so the setting that is not being edited stays
// legible.
//
// Every rule this view could get wrong lives in logic/Catalog.js: membership,
// grouping and sort, secondary text, proof badges, the interlock, and every
// count. This file binds to what that returns and owns the transport side —
// the optimistic overrides, the coalescing runner over the control CLI, and
// the single re-read when the runner drains.
Item {
  id: modelsRoot

  // ------------------------------------------------------------- contract

  property var service: null
  // The panel, for cross-view navigation (the empty state points at
  // Providers). Views are selected by index there.
  property var panel: null
  property double nowMs: 0
  // True while this is the panel's visible view: the snapshot is fetched on
  // first entry rather than on a timer, and the proof re-read only runs for
  // a reader.
  property bool active: false

  // Palette, handed over by the panel.
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(modelsRoot.foreground, 1.55)
  property string fontFamily: Style.font.family

  // ------------------------------------------------------- derived state

  readonly property bool controlsReachable: !!service && service.online
    && service.hasCallerSecret

  // Which setting the single list edits: "picker" or "subagents".
  property string setting: "picker"

  // Session-scoped collapse state, keyed by provider id. Var-property
  // objects only notify on reassignment, so every change rebuilds it.
  property var collapsed: ({})

  // Toggles that have been clicked but whose control command has not been
  // reconciled yet, keyed {picker: {slug: bool}, subagents: {slug: bool}}.
  // The view model reads these ahead of the snapshot, which is what makes a
  // toggle answer the instant it is clicked.
  property var overrides: ({ picker: ({}), subagents: ({}) })

  readonly property var codexTarget: service ? service.codexTarget : ({})

  readonly property var viewModel: Catalog.viewModel(modelsRoot.codexTarget, {
    setting: modelsRoot.setting,
    overrides: modelsRoot.overrides,
    collapsed: modelsRoot.collapsed
  })

  readonly property bool pickerSetting: modelsRoot.setting === "picker"

  height: column.implicitHeight

  // --------------------------------------------------------- lazy loading

  // The catalog is not a payload of its own: it rides in the same
  // control_snapshot the MODES switches and the provider toggles read, so
  // opening the panel at all pays for it and this view cannot make that
  // cheaper without splitting the router's own command. What it can do is
  // start nothing extra.
  //
  // First entry pays for the snapshot if nothing else has read it yet. After
  // that the panel's own refresh and the post-mutation re-read keep it
  // current — this view starts no timer of its own except the proof re-read
  // below. Entering while the router is unreachable must not strand the view
  // on an empty list, so reachability arriving later is a second trigger.
  onActiveChanged: {
    modelsRoot._loadIfNeeded()
    // Leaving with a change that nothing will ever reconcile — a failed
    // read, a router that went away — must not park an optimistic toggle
    // for the next visit. A read that is still on its way is not that case:
    // dropping the toggle here would show the pre-mutation state until it
    // lands, and re-entering asks for no new read because the snapshot it
    // finds is not null.
    if (!modelsRoot.active && !modelsRoot.busy
        && modelsRoot._queue.length === 0 && !modelsRoot._reconciling)
      modelsRoot.overrides = { picker: ({}), subagents: ({}) }
  }
  onControlsReachableChanged: {
    modelsRoot._loadIfNeeded()
    // Nothing is coming to confirm a pending toggle while the router is
    // away, so stop showing it as if something were.
    if (!modelsRoot.controlsReachable) modelsRoot._giveUpReconciling()
  }

  function _loadIfNeeded() {
    if (!modelsRoot.active || !modelsRoot.controlsReachable) return
    if (!modelsRoot.service.snapshot) modelsRoot.service.refreshData()
  }

  // The one state the router changes on its own: a capability probe running
  // in the background settles into proven or failed without anybody asking.
  // Re-read on a short interval while a visible row says "Working…", and
  // stop the moment none do.
  Timer {
    interval: 4000
    repeat: true
    running: modelsRoot.active && modelsRoot.controlsReachable
      && modelsRoot.viewModel.anyChecking && !modelsRoot.busy
    onTriggered: modelsRoot.service.refreshData()
  }

  // ------------------------------------------------------------ mutations
  //
  // Every setter here is a control-CLI process spawn: the loopback HTTP
  // surface is read-only by the router's deliberate design. Clicks must not
  // wait for one, so the toggle flips into `overrides` immediately and the
  // intent joins a queue that runs one command at a time. Repeated intents
  // for the same model collapse to the last one, so impatient re-toggling
  // settles on what was chosen last instead of queueing contradictory work.

  property var _queue: []
  property bool busy: false
  // Label of the command running now, and the last failure with the intent
  // it belongs to. They are separate because a queue keeps moving: the next
  // command's busy label must not erase the reason the previous one failed.
  property string runningLabel: ""
  property string errorNotice: ""
  property string _errorKey: ""

  readonly property string notice: modelsRoot.busy
    ? modelsRoot.runningLabel + "…" : modelsRoot.errorNotice

  // The service's read-round counter as it stood when the queue last
  // drained. Only a round that *began* after that can answer for everything
  // that ran; a round that merely finishes later may have started before the
  // change landed.
  property int _settledRound: 0
  property bool _reconciling: false

  // Switching the setting moves the operator away from the row that failed,
  // so its message goes with them.
  onSettingChanged: {
    modelsRoot.errorNotice = ""
    modelsRoot._errorKey = ""
  }

  function _cloneOverrides() {
    var next = { picker: ({}), subagents: ({}) }
    var settings = ["picker", "subagents"]
    for (var s = 0; s < settings.length; s++) {
      var name = settings[s]
      var bucket = modelsRoot.overrides[name] || ({})
      for (var slug in bucket) next[name][slug] = bucket[slug]
    }
    return next
  }

  function _setOverride(setting, slug, value) {
    var next = modelsRoot._cloneOverrides()
    if (value === null) delete next[setting][slug]
    else next[setting][slug] = value
    modelsRoot.overrides = next
  }

  function _queuedFor(key) {
    for (var i = 0; i < modelsRoot._queue.length; i++)
      if (modelsRoot._queue[i].key === key) return true
    return false
  }

  // key identifies what an intent is about, so a second click on the same
  // row replaces the queued one instead of adding to it.
  function _enqueue(intent) {
    var next = []
    for (var i = 0; i < modelsRoot._queue.length; i++)
      if (modelsRoot._queue[i].key !== intent.key) next.push(modelsRoot._queue[i])
    next.push(intent)
    modelsRoot._queue = next
    if (modelsRoot._errorKey === intent.key) {
      modelsRoot.errorNotice = ""
      modelsRoot._errorKey = ""
    }
    modelsRoot._drain()
  }

  function _drain() {
    if (modelsRoot.busy) return
    if (modelsRoot._queue.length === 0) {
      modelsRoot._settle()
      return
    }
    if (!modelsRoot.controlsReachable) {
      modelsRoot._abort("Router unreachable — the change was not applied.")
      return
    }

    var next = modelsRoot._queue.slice(1)
    var intent = modelsRoot._queue[0]
    modelsRoot._queue = next
    modelsRoot.busy = true
    modelsRoot.runningLabel = intent.label
    // The service's own "mutate, then re-read" would fire once per command;
    // this view reconciles once, when the whole queue has drained.
    modelsRoot.service.deferAutoRefresh = true

    modelsRoot.service.runControl(intent.label, intent.args, function(error) {
      modelsRoot.busy = false
      if (error !== null) {
        // Never leave a setting on screen that did not take — unless a newer
        // click for the same row is already queued, in which case that
        // intent owns the override and reverting would flap the switch.
        if (intent.setting !== "" && intent.slug !== "" && !modelsRoot._queuedFor(intent.key))
          modelsRoot._setOverride(intent.setting, intent.slug, null)
        modelsRoot.errorNotice = error
        modelsRoot._errorKey = intent.key
      } else if (modelsRoot._errorKey === intent.key) {
        // The retry of the thing that failed worked; its message is stale.
        modelsRoot.errorNotice = ""
        modelsRoot._errorKey = ""
      }
      modelsRoot._drain()
    })
  }

  // The queue is empty: ask for the one read that reconciles everything that
  // ran. The deferral stays on across this call deliberately — the control
  // process emits its jobSucceeded *after* the callback that got us here,
  // and its own re-read would be the second one. Releasing it through
  // Qt.callLater lets that signal be swallowed and hands the policy back
  // before anything else can mutate.
  function _settle() {
    if (!modelsRoot.service) {
      modelsRoot._giveUpReconciling()
      return
    }
    if (!modelsRoot.controlsReachable) {
      // refreshData() would no-op, so no read is coming: show what is known
      // rather than a setting nothing can confirm.
      modelsRoot._giveUpReconciling()
      Qt.callLater(modelsRoot._releaseDeferral)
      return
    }
    modelsRoot._settledRound = modelsRoot.service.dataRound
    modelsRoot._reconciling = true
    modelsRoot.service.refreshData()
    Qt.callLater(modelsRoot._releaseDeferral)
  }

  // A pending toggle that nothing will confirm goes back to what the last
  // successful read said. Never on screen: a setting that did not take.
  //
  // Unconditional on purpose. Guarding on `_reconciling` would skip exactly
  // the case that needs this most — the router going away before the drain,
  // so a toggle was applied optimistically while no read was ever expected.
  function _giveUpReconciling() {
    modelsRoot._reconciling = false
    modelsRoot.overrides = { picker: ({}), subagents: ({}) }
  }

  function _releaseDeferral() {
    if (modelsRoot.service) modelsRoot.service.deferAutoRefresh = false
  }

  // Nothing can be applied: drop the queue, drop every optimistic toggle so
  // the panel stops showing settings that did not take, and never leave the
  // service's refresh policy switched off behind us.
  function _abort(message) {
    modelsRoot._queue = []
    modelsRoot.overrides = { picker: ({}), subagents: ({}) }
    modelsRoot._reconciling = false
    modelsRoot.errorNotice = message
    modelsRoot._errorKey = ""
    Qt.callLater(modelsRoot._releaseDeferral)
  }

  Connections {
    target: modelsRoot.service
    enabled: !!modelsRoot.service

    // A fresh snapshot has landed. It reconciles this view only if its round
    // began after the last command finished and nothing is pending — a round
    // already in flight carries pre-mutation data, and clearing the
    // optimistic toggles against it would show the operator the old state.
    //
    // Bound to the snapshot rather than to the round closing: a round can
    // close having refreshed usage while the catalog read itself failed, and
    // that answers for nothing here.
    function onSnapshotChanged() {
      if (!modelsRoot._reconciling) return
      if (modelsRoot.busy || modelsRoot._queue.length > 0) return
      if (modelsRoot.service.dataRound <= modelsRoot._settledRound) return
      modelsRoot._reconciling = false
      modelsRoot.overrides = { picker: ({}), subagents: ({}) }
    }

    // The round this view was waiting for has closed. A fresh snapshot
    // would already have retired the overrides above — the service assigns
    // it before the round closes — so reaching here means the catalog read
    // failed, and waiting for a confirmation that never came would park the
    // optimistic toggle on screen indefinitely.
    function onDataLoadingChanged() {
      if (modelsRoot.service.dataLoading) return
      if (!modelsRoot._reconciling) return
      if (modelsRoot.busy || modelsRoot._queue.length > 0) return
      if (modelsRoot.service.dataRound <= modelsRoot._settledRound) return
      modelsRoot._giveUpReconciling()
    }
  }

  function toggleRow(row) {
    if (!row || row.toggleEnabled !== true) return
    var wanted = !(row.on === true)
    modelsRoot._setOverride(modelsRoot.setting, row.slug, wanted)
    if (modelsRoot.pickerSetting) {
      modelsRoot._enqueue({
        key: "picker:" + row.slug,
        setting: "picker",
        slug: row.slug,
        label: (wanted ? "Showing " : "Hiding ") + row.displayName,
        args: ["picker", "set", row.slug, wanted ? "show" : "hide"]
      })
    } else {
      modelsRoot._enqueue({
        key: "subagents:" + row.slug,
        setting: "subagents",
        slug: row.slug,
        label: (wanted ? "Enabling " : "Disabling ") + row.displayName + " as a subagent",
        args: ["subagents", "set", row.slug, wanted ? "on" : "off"]
      })
    }
  }

  // Bulk changes go through the router's own whole-list and per-provider
  // verbs — never a loop of per-model calls, which would be one process
  // spawn per model. They are not optimistic: a single verb's effect is what
  // the reconciling re-read paints.
  function runBulk(key, label, args) {
    modelsRoot._enqueue({ key: key, setting: "", slug: "", label: label, args: args })
  }

  function bulkAll(on) {
    if (modelsRoot.pickerSetting)
      modelsRoot.runBulk("picker:all", on ? "Showing every model" : "Hiding every model",
        ["picker", "all", on ? "show" : "hide"])
    else
      modelsRoot.runBulk("subagents:all",
        on ? "Enabling every proven model" : "Clearing subagent selection",
        ["subagents", on ? "select-all" : "unselect-all"])
  }

  function bulkProvider(providerId, on) {
    if (modelsRoot.pickerSetting)
      modelsRoot.runBulk("picker:provider:" + providerId,
        (on ? "Showing " : "Hiding ") + providerId + " models",
        ["picker", "provider", providerId, on ? "show" : "hide"])
    else
      modelsRoot.runBulk("subagents:provider:" + providerId,
        providerId + (on ? " models on as subagents" : " models off as subagents"),
        ["subagents", "provider", providerId, on ? "on" : "off"])
  }

  function toggleCollapsed(providerId) {
    var next = ({})
    for (var id in modelsRoot.collapsed) next[id] = modelsRoot.collapsed[id]
    next[providerId] = !(modelsRoot.collapsed[providerId] === true)
    modelsRoot.collapsed = next
  }

  function showPicker() {
    modelsRoot.setting = "picker"
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.md

    PanelSectionHeader {
      width: parent.width
      text: "MODELS"
      foreground: modelsRoot.foreground
      fontFamily: modelsRoot.fontFamily
    }

    // ---------- Sub-switcher: which setting the list edits ----------
    Row {
      width: parent.width
      spacing: Style.spacing.sm
      visible: modelsRoot.controlsReachable && !modelsRoot.viewModel.empty

      readonly property real cellWidth: (width - spacing) / 2

      Button {
        width: parent.cellWidth
        text: Catalog.switcherLabel("picker", modelsRoot.viewModel.totals)
        selected: modelsRoot.pickerSetting
        bordered: true
        foreground: modelsRoot.foreground
        fontFamily: modelsRoot.fontFamily
        fontSize: Style.font.caption
        verticalPadding: Style.spacing.controlPaddingY
        onClicked: modelsRoot.setting = "picker"
      }

      Button {
        width: parent.cellWidth
        text: Catalog.switcherLabel("subagents", modelsRoot.viewModel.totals)
        selected: !modelsRoot.pickerSetting
        bordered: true
        foreground: modelsRoot.foreground
        fontFamily: modelsRoot.fontFamily
        fontSize: Style.font.caption
        verticalPadding: Style.spacing.controlPaddingY
        onClicked: modelsRoot.setting = "subagents"
      }
    }

    // ---------- Subagent mode: meaningless under Picker, so absent there ----------
    Toggle {
      width: parent.width
      visible: modelsRoot.controlsReachable && !modelsRoot.viewModel.empty
        && !modelsRoot.pickerSetting
      label: "Every catalog model as a subagent"
      description: "Expose every catalog model visible in the picker, including routes that have never been shown to work as a subagent."
      checked: modelsRoot.viewModel.allCatalogModels
      foreground: modelsRoot.foreground
      accent: Color.accent
      fontFamily: modelsRoot.fontFamily
      onClicked: modelsRoot.runBulk("subagents:mode",
        modelsRoot.viewModel.allCatalogModels
          ? (modelsRoot.viewModel.hasSelection
              ? "Switching to your selected subagents"
              : "Switching to registry-certified subagents")
          : "Switching to every catalog model as a subagent",
        ["subagents", "mode", modelsRoot.viewModel.allCatalogModels
          ? (modelsRoot.viewModel.hasSelection ? "selected" : "proven") : "all"])
    }

    // ---------- Bulk actions over the whole list ----------
    Row {
      width: parent.width
      spacing: Style.spacing.sm
      visible: modelsRoot.controlsReachable && !modelsRoot.viewModel.empty

      readonly property real cellWidth: (width - spacing) / 2

      Button {
        width: parent.cellWidth
        text: modelsRoot.pickerSetting ? "Show all" : "Subagents on"
        bordered: true
        foreground: modelsRoot.foreground
        fontFamily: modelsRoot.fontFamily
        fontSize: Style.font.caption
        onClicked: modelsRoot.bulkAll(true)
      }

      Button {
        width: parent.cellWidth
        text: modelsRoot.pickerSetting ? "Hide all" : "Subagents off"
        bordered: true
        foreground: modelsRoot.foreground
        fontFamily: modelsRoot.fontFamily
        fontSize: Style.font.caption
        onClicked: modelsRoot.bulkAll(false)
      }
    }

    // ---------- Provider groups ----------
    Repeater {
      model: modelsRoot.viewModel.groups

      Column {
        required property var modelData

        width: parent.width
        spacing: Style.spacing.sm

        // Group header: name, what the visible setting counts, and the
        // collapse affordance — one nineteen-model provider must not bury
        // the rest of the list.
        Item {
          width: parent.width
          implicitHeight: Math.max(groupName.implicitHeight, groupSummary.implicitHeight)

          Text {
            textFormat: Text.PlainText
            id: groupName
            anchors.left: parent.left
            anchors.right: groupSummary.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: (modelData.collapsed ? "▸ " : "▾ ") + String(modelData.providerName)
            color: modelsRoot.foreground
            font.family: modelsRoot.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            id: groupSummary
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: String(modelData.summary)
            color: modelsRoot.dim
            font.family: modelsRoot.fontFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: modelsRoot.toggleCollapsed(modelData.providerId)
          }
        }

        // The same pair of actions as the whole list, scoped to one account.
        Row {
          width: parent.width
          spacing: Style.spacing.sm
          visible: !modelData.collapsed

          readonly property real cellWidth: (width - spacing) / 2

          Button {
            width: parent.cellWidth
            text: modelsRoot.pickerSetting ? "Show all" : "Subagents on"
            foreground: modelsRoot.foreground
            fontFamily: modelsRoot.fontFamily
            fontSize: Style.font.caption
            onClicked: modelsRoot.bulkProvider(modelData.providerId, true)
          }

          Button {
            width: parent.cellWidth
            text: modelsRoot.pickerSetting ? "Hide all" : "Subagents off"
            foreground: modelsRoot.foreground
            fontFamily: modelsRoot.fontFamily
            fontSize: Style.font.caption
            onClicked: modelsRoot.bulkProvider(modelData.providerId, false)
          }
        }

        Repeater {
          model: modelData.collapsed ? [] : modelData.models

          CatalogRow {
            required property var modelData

            width: parent.width
            row: modelData
            locked: !modelsRoot.controlsReachable
            foreground: modelsRoot.foreground
            urgent: modelsRoot.urgent
            dim: modelsRoot.dim
            fontFamily: modelsRoot.fontFamily
            onToggleRequested: modelsRoot.toggleRow(modelData)
            // Only the hidden-in-picker interlock emits this action; the v1
            // certification interlock explains itself and remains inert.
            onInterlockRequested: modelsRoot.showPicker()
          }
        }
      }
    }

    // ---------- Empty and unreachable states ----------
    Text {
      textFormat: Text.PlainText
      visible: !modelsRoot.controlsReachable
      width: parent.width
      text: !modelsRoot.service || !modelsRoot.service.online
        ? "Router offline — no catalog to show."
        : "Caller key missing — the catalog cannot be read."
      color: modelsRoot.dim
      font.family: modelsRoot.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: modelsRoot.controlsReachable && modelsRoot.viewModel.empty
      width: parent.width
      text: "No catalog models — every provider is disabled."
      color: modelsRoot.dim
      font.family: modelsRoot.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    Button {
      width: parent.width
      visible: modelsRoot.controlsReachable && modelsRoot.viewModel.empty
      text: "Open Providers"
      bordered: true
      foreground: modelsRoot.foreground
      fontFamily: modelsRoot.fontFamily
      fontSize: Style.font.bodySmall
      onClicked: if (modelsRoot.panel) modelsRoot.panel.selectedView = 2
    }

    // Busy line while a command runs, the router's own message when one
    // failed and the toggle reverted.
    ActionNotice {
      width: parent.width
      notice: modelsRoot.notice
      running: modelsRoot.busy
      dim: modelsRoot.dim
      urgent: modelsRoot.urgent
      fontFamily: modelsRoot.fontFamily
    }
  }
}
