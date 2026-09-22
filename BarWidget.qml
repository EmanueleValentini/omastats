import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar label: a few live numbers, and the door to the full panel.
//
// Which numbers is a per-entry setting in shell.json ("metrics"), because
// what belongs in a bar is a matter of taste and of how much horizontal
// room is left. Everything the plugin can measure is in the panel either
// way, so the bar can stay short without hiding anything.
//
// Left click opens the panel, right click cycles the metric presets, middle
// click drops into btop for the things a bar cannot show.
BarWidget {
  id: root
  moduleName: "io.github.emanuelevalentini.omastats"

  // The sampler lives in the plugin's service instance so that a bar on
  // each monitor still reads /proc once. A plugin enabled as a bar widget
  // only — or one whose service has not finished loading — falls back to a
  // local sampler so the widget is never blank.
  readonly property var sharedStats: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(root.moduleName)
    : null
  readonly property var stats: sharedStats || localStats.item

  readonly property var metrics: Model.normalizeMetrics(setting("metrics", ["cpu", "mem", "net"]))
  readonly property bool showIcons: setting("showIcons", true) === true
  readonly property int sampleInterval: Math.max(250, setting("interval", 1000))
  readonly property bool wantsGpu: Model.metricNeedsGpu(metrics)

  readonly property var segments: stats ? Model.barSegments(metrics, {
    cpu: stats.cpuPercent,
    cpuTemperature: stats.cpuTemperature,
    memory: stats.memory,
    gpu: stats.gpu,
    netRx: stats.netRx,
    netTx: stats.netTx,
    diskRead: stats.diskRead,
    diskWrite: stats.diskWrite
  }, showIcons) : []

  readonly property string tooltipSummary: {
    if (!stats) return "System statistics"
    var parts = [
      "CPU " + Model.formatPercent(stats.cpuPercent),
      "RAM " + Model.formatPercent(stats.memory.percent),
      "NET ↓" + Model.formatRate(stats.netRx) + " ↑" + Model.formatRate(stats.netTx)
    ]
    if (isFinite(stats.cpuTemperature)) parts.splice(1, 0, Model.formatTemperature(stats.cpuTemperature) + "C")
    if (stats.gpu && isFinite(stats.gpu.utilization)) parts.push("GPU " + Model.formatPercent(stats.gpu.utilization))
    return parts.join("  ·  ")
  }

  // ---- Sampler lifetime. Consumers announce themselves so the sampler can
  //      keep the expensive parts (the GPU helper) off until something is
  //      actually showing GPU numbers.
  property var retainTarget: null
  property var retainedKinds: ({})

  function updateRetains() {
    var target = root.stats

    if (target !== retainTarget) {
      if (retainTarget) {
        for (var previous in retainedKinds) {
          if (retainedKinds[previous]) retainTarget.release(previous)
        }
      }
      retainedKinds = ({})
      retainTarget = target
    }

    if (!target) return

    // Applied here rather than through a binding: the sampler is shared, so
    // its interval belongs to whoever most recently claimed it, not to a
    // binding from one widget instance that would fight the others.
    target.interval = root.sampleInterval

    var wanted = { base: true, gpu: root.wantsGpu }
    for (var kind in wanted) {
      var want = wanted[kind] === true
      if (want === (retainedKinds[kind] === true)) continue
      if (want) target.retain(kind)
      else target.release(kind)
      retainedKinds[kind] = want
    }
  }

  function releaseAll() {
    if (!retainTarget) return
    for (var kind in retainedKinds) {
      if (retainedKinds[kind]) retainTarget.release(kind)
    }
    retainedKinds = ({})
    retainTarget = null
  }

  onWantsGpuChanged: updateRetains()

  onStatsChanged: {
    updateRetains()
    injectPanel()
  }
  Component.onCompleted: updateRetains()
  Component.onDestruction: releaseAll()

  onSampleIntervalChanged: if (stats) stats.interval = sampleInterval


  // ---- Metric presets, cycled by right click. Same write-through as the
  //      clock's label formats: applied locally so the bar changes on the
  //      click, then persisted so it survives a restart.
  readonly property var metricPresets: [
    ["cpu", "mem", "net"],
    ["cpu", "cpuTemp", "mem"],
    ["cpu", "cpuTemp", "mem", "gpu", "gpuTemp"],
    ["cpu", "cpuTemp", "mem", "swap", "gpu", "gpuTemp", "gpuWatt", "net", "disk"],
    ["cpu"]
  ]

  function cycleMetrics() {
    var current = metrics.join(",")
    var index = -1
    for (var i = 0; i < metricPresets.length; i++) {
      if (metricPresets[i].join(",") === current) index = i
    }

    var next = metricPresets[(index + 1) % metricPresets.length]
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.metrics = next

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---- Panel. Shape contract for the bar's summon/hide routing:
  //      open/close/opened have to live on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("stats" in target) target.stats = root.stats
  }

  readonly property real openPanelIndicatorWidth: contentRow.width
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: localStats
    active: !root.sharedStats
    source: Qt.resolvedUrl("Stats.qml")
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The bar mounts one widget per monitor plus a placeholder slot, and an
  // IPC target only ever routes to whichever of them registered first. So
  // the handler asks the bar which copy a hotkey should act on instead of
  // acting on itself — the same choice `omarchy-shell shell summon` makes.
  function routeOpen() {
    if (root.bar && typeof root.bar.summonBarWidget === "function" && root.bar.summonBarWidget(root.moduleName)) return
    root.open()
  }

  function routeClose() {
    if (root.bar && typeof root.bar.hideBarWidget === "function" && root.bar.hideBarWidget(root.moduleName)) return
    root.close()
  }

  function routeToggle() {
    if (root.bar && typeof root.bar.isBarWidgetOpen === "function") {
      if (root.bar.isBarWidgetOpen(root.moduleName)) routeClose()
      else routeOpen()
      return
    }
    root.togglePanel()
  }

  IpcHandler {
    target: "omastats"

    function open(): void { root.routeOpen() }
    function close(): void { root.routeClose() }
    function show(): void { root.routeOpen() }
    function hide(): void { root.routeClose() }
    function toggle(): void { root.routeToggle() }
    function cycleMetrics(): void { root.broadcast("cycleMetrics") }
  }

  function segmentColor(level) {
    if (level === "critical") return button.activeColor
    if (level === "warn") return Style.hoverStateColor(button.foreground, Color.accent)
    return button.foreground
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The label is drawn per segment below so a hot number can color itself
    // without dragging the rest of the label with it.
    labelVisible: false
    hasVisualContent: root.segments.length > 0
    tooltipText: root.tooltipSummary
    horizontalMargin: 8.75
    verticalPadding: 8.75
    fixedWidth: root.vertical ? -1 : Math.round(contentRow.implicitWidth + scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.round(contentRow.implicitHeight + scaledVerticalPadding * 2) : -1

    onPressed: function(pressedButton) {
      if (pressedButton === Qt.RightButton) root.cycleMetrics()
      else if (pressedButton === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-launch-tui btop") }
      else root.togglePanel()
    }

    // One row of segments horizontally; one stacked block per segment when
    // the bar runs down the side of the screen.
    Grid {
      id: contentRow
      anchors.centerIn: parent
      columns: root.vertical ? 1 : root.segments.length
      rows: root.vertical ? root.segments.length : 1
      horizontalItemAlignment: Grid.AlignHCenter
      verticalItemAlignment: Grid.AlignVCenter
      spacing: root.vertical ? Style.space(4) : Style.space(11)

      Repeater {
        model: root.segments

        Column {
          required property var modelData
          spacing: Style.space(1)

          Text {
            // Horizontally the icon is part of the value's own text run, so
            // it only gets a line of its own on a vertical bar.
            visible: root.vertical && root.showIcons && modelData.icon !== ""
            anchors.horizontalCenter: root.vertical ? parent.horizontalCenter : undefined
            text: modelData.icon
            color: root.segmentColor(modelData.level)
            font.family: button.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
          }

          Text {
            anchors.horizontalCenter: root.vertical ? parent.horizontalCenter : undefined
            text: root.vertical ? root.verticalText(modelData) : modelData.label
            color: root.segmentColor(modelData.level)
            font.family: button.fontFamily
            font.pixelSize: root.vertical ? Math.round(Style.font.bodySmall * 0.92) : button.fontSize
            horizontalAlignment: Text.AlignHCenter
            renderType: Text.NativeRendering

            Behavior on color {
              enabled: !root.bar || root.bar.foregroundAnimationEnabled
              ColorAnimation { duration: 160 }
            }
          }
        }
      }
    }
  }

  // Vertical bars are narrow: the two halves of a rate ("↓1.2M ↑340K") go on
  // their own lines rather than being elided.
  function verticalText(segment) {
    return String(segment.text).replace(" ", "\n")
  }
}
