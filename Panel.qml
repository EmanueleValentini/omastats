import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The full read-out: everything the sampler collects, in one scrollable
// column, ordered the way you go looking for it when a machine feels slow —
// CPU, memory, GPU, temperatures, disks, network, and finally which
// processes are responsible.
//
// Opening the panel is also what turns the expensive sampling on (df, ps,
// the GPU helper); closing it turns them back off. BarWidget.qml owns the
// bar label and hands this panel the button to anchor against.
Panel {
  id: root
  moduleName: "io.github.emanuelevalentini.omastats"
  ipcTarget: "omastats"
  manageIpc: false

  property var anchorItem: null
  property var stats: null

  // The bar tracks the widget mounted in its slot, not this nested panel,
  // so everything the bar identifies a panel by has to be that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(contentForeground, 1.5)
  readonly property color fainterForeground: Qt.darker(contentForeground, 1.9)

  readonly property int panelWidth: Style.space(560)
  readonly property int sparklineHeight: Style.space(46)

  readonly property var memory: stats ? stats.memory : ({ total: 0, used: 0, percent: 0, cached: 0, available: 0, swapTotal: 0, swapUsed: 0, swapPercent: 0 })
  readonly property var gpu: stats ? stats.gpu : null
  readonly property bool hasGpu: gpu !== null && gpu !== undefined

  // ---- Sampling lifetime. The panel is the only consumer of the process
  //      list, the filesystem table, and (unless the bar shows a GPU
  //      number) the GPU helper.
  property bool holdingDetail: false

  function updateHold() {
    var want = root.opened && root.stats !== null
    if (want === holdingDetail) return

    if (want) {
      root.stats.retain("detail")
      root.stats.retain("gpu")
    } else if (root.stats) {
      root.stats.release("detail")
      root.stats.release("gpu")
    }
    holdingDetail = want
  }

  onOpenedChanged: {
    updateHold()
    if (opened) Qt.callLater(root.scrollToTop)
  }
  onStatsChanged: updateHold()
  Component.onDestruction: {
    if (holdingDetail && stats) {
      stats.release("detail")
      stats.release("gpu")
    }
  }

  // The panel is taller than most screens, so it scrolls. Reopening always
  // starts at the top: the hero is the point of the panel, and a panel that
  // reopens halfway down looks broken.
  property var flickable: null

  function scrollBy(delta) {
    if (!flickable) return
    var limit = Math.max(0, flickable.contentHeight - flickable.height)
    flickable.contentY = Math.max(0, Math.min(limit, flickable.contentY + delta))
  }

  function scrollToTop() {
    if (flickable) flickable.contentY = 0
  }

  function open() {
    root.controller.show()
    Qt.callLater(root.scrollToTop)
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function levelColor(level) {
    if (level === "critical") return Color.urgent
    if (level === "warn") return Style.hoverStateColor(contentForeground, Color.accent)
    return contentForeground
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Anchored under the widget rather than centered on the bar: the panel
    // belongs to the reading you clicked, and a right-hand widget opening a
    // panel in the middle of the screen reads as someone else's popup.
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // Arrow keys page the column. Set outright rather than flicked: a
      // flick's velocity carries past whatever it was aimed at.
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.scrollBy(dy * Style.space(120))
      }

      Flickable {
        id: content
        anchors.fill: parent
        Component.onCompleted: root.flickable = content
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: content.width
          spacing: Style.space(12)

          // ---- Hero: the one number worth reading from across the room,
          //      with the machine's own vitals beside it. Anchored rather
          //      than laid out in a row: the vitals column has to give way
          //      to the number, not push it off the panel.
          Item {
            width: parent.width
            height: Math.max(heroLeft.height, heroRight.height)

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(14)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "\u{F061A}"
                color: root.levelColor(Model.loadLevel(root.stats ? root.stats.cpuPercent : 0))
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale: sized to read at the cap height of the number.
                font.pixelSize: 40
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Model.formatPercent(root.stats ? root.stats.cpuPercent : 0)
                color: root.levelColor(Model.loadLevel(root.stats ? root.stats.cpuPercent : 0))
                font.family: root.contentFontFamily
                font.pixelSize: 38
                font.bold: true
              }
            }

            Column {
              id: heroRight
              anchors.left: heroLeft.right
              anchors.leftMargin: Style.space(16)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
                text: root.stats && root.stats.cpuModel !== "" ? root.stats.cpuModel : "System"
                color: root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: {
                  var load = root.stats ? root.stats.loadAverage : { one: 0, five: 0, fifteen: 0 }
                  return "load " + load.one.toFixed(2) + "  " + load.five.toFixed(2) + "  " + load.fifteen.toFixed(2)
                }
                color: root.fainterForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: "up " + Model.formatUptime(root.stats ? root.stats.uptimeSeconds : 0)
                  + (root.stats && root.stats.coreCount > 0 ? "   ·   " + root.stats.coreCount + " threads" : "")
                color: root.fainterForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Sparkline {
            width: parent.width
            height: root.sparklineHeight
            values: root.stats ? root.stats.cpuHistory : []
            capacity: root.stats ? root.stats.historyLength : 90
            stroke: Style.selectedStateColor(root.contentForeground, Color.accent)
            maxValue: 100
          }

          // ---- CPU
          PanelSectionHeader {
            text: "PROCESSOR"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Meter {
            width: parent.width
            label: "Clock"
            value: Model.formatMhz(root.stats ? root.stats.cpuMhz : 0)
            showTrack: false
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Meter {
            visible: root.stats && isFinite(root.stats.cpuTemperature)
            width: parent.width
            label: "Temperature"
            value: root.stats ? Model.formatTemperature(root.stats.cpuTemperature) + "C" : "—"
            percent: root.stats ? Math.min(100, root.stats.cpuTemperature) : 0
            level: root.stats ? Model.temperatureLevel(root.stats.cpuTemperature) : "normal"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          // Per-core load, two columns. A single busy core on an otherwise
          // idle machine is the difference between "it is compiling" and
          // "something is wrong", and the aggregate number hides it.
          Grid {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(18)
            rowSpacing: Style.space(4)

            Repeater {
              model: root.stats ? root.stats.cpuCores : []

              Meter {
                required property var modelData
                required property int index

                width: Math.round((column.width - Style.space(18)) / 2)
                label: "Core " + index
                value: Model.formatPercent(modelData)
                percent: modelData
                level: Model.loadLevel(modelData)
                labelWidth: Style.space(50)
                valueWidth: Style.space(44)
                trackHeight: Style.space(4)
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Memory
          PanelSectionHeader {
            text: "MEMORY"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Meter {
            width: parent.width
            label: "RAM"
            value: Model.formatBytesLong(root.memory.used) + " / " + Model.formatBytesLong(root.memory.total)
            percent: root.memory.percent
            level: Model.loadLevel(root.memory.percent)
            valueWidth: Style.space(150)
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Sparkline {
            width: parent.width
            height: Style.space(32)
            values: root.stats ? root.stats.memHistory : []
            capacity: root.stats ? root.stats.historyLength : 90
            stroke: Style.selectedStateColor(root.contentForeground, Color.accent)
            maxValue: 100
          }

          Meter {
            visible: root.memory.swapTotal > 0
            width: parent.width
            label: "Swap"
            value: Model.formatBytesLong(root.memory.swapUsed) + " / " + Model.formatBytesLong(root.memory.swapTotal)
            percent: root.memory.swapPercent
            level: Model.loadLevel(root.memory.swapPercent)
            valueWidth: Style.space(150)
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Text {
            width: parent.width
            text: "cache " + Model.formatBytesLong(root.memory.cached) + "   ·   available " + Model.formatBytesLong(root.memory.available)
            color: root.fainterForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          // ---- GPU. The whole block stays out of the layout on a machine
          //      whose GPU cannot be read, rather than showing empty rows.
          PanelSeparator {
            visible: root.hasGpu
            width: parent.width
            foreground: root.contentForeground
          }

          PanelSectionHeader {
            visible: root.hasGpu
            text: "GRAPHICS"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Text {
            visible: root.hasGpu
            width: parent.width
            text: root.hasGpu ? root.gpu.name : ""
            color: root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Meter {
            visible: root.hasGpu && isFinite(root.gpu.utilization)
            width: parent.width
            label: "Load"
            value: root.hasGpu ? Model.formatPercent(root.gpu.utilization) : "—"
            percent: root.hasGpu ? root.gpu.utilization : 0
            level: root.hasGpu ? Model.loadLevel(root.gpu.utilization) : "normal"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Sparkline {
            visible: root.hasGpu
            width: parent.width
            height: Style.space(32)
            values: root.stats ? root.stats.gpuHistory : []
            capacity: root.stats ? root.stats.historyLength : 90
            stroke: Style.selectedStateColor(root.contentForeground, Color.accent)
            maxValue: 100
          }

          Meter {
            visible: root.hasGpu && isFinite(root.gpu.memoryPercent)
            width: parent.width
            label: "VRAM"
            value: root.hasGpu ? Model.formatBytesLong(root.gpu.memoryUsed) + " / " + Model.formatBytesLong(root.gpu.memoryTotal) : "—"
            percent: root.hasGpu ? root.gpu.memoryPercent : 0
            level: root.hasGpu ? Model.loadLevel(root.gpu.memoryPercent) : "normal"
            valueWidth: Style.space(150)
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Meter {
            visible: root.hasGpu && isFinite(root.gpu.temperature)
            width: parent.width
            label: "Temperature"
            value: root.hasGpu ? Model.formatTemperature(root.gpu.temperature) + "C" : "—"
            percent: root.hasGpu ? Math.min(100, root.gpu.temperature) : 0
            level: root.hasGpu ? Model.temperatureLevel(root.gpu.temperature) : "normal"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Text {
            visible: root.hasGpu
            width: parent.width
            text: {
              if (!root.hasGpu) return ""
              var parts = []
              if (isFinite(root.gpu.clockMhz)) parts.push("clock " + Model.formatMhz(root.gpu.clockMhz))
              if (isFinite(root.gpu.power)) parts.push("power " + root.gpu.power.toFixed(0) + " W")
              if (isFinite(root.gpu.fanPercent)) parts.push("fan " + Model.formatPercent(root.gpu.fanPercent))
              return parts.join("   ·   ")
            }
            color: root.fainterForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Temperatures. Every sensor the machine exposes, grouped by
          //      chip, so a hot NVMe or a hot chipset is findable here
          //      rather than only in the CPU's own number.
          PanelSectionHeader {
            text: "TEMPERATURES"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Grid {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(18)
            rowSpacing: Style.space(3)

            Repeater {
              model: root.stats ? root.stats.sensors : []

              Item {
                required property var modelData

                width: Math.round((column.width - Style.space(18)) / 2)
                height: sensorLabel.implicitHeight + Style.space(2)

                Text {
                  id: sensorLabel
                  anchors.left: parent.left
                  anchors.right: sensorValue.left
                  anchors.rightMargin: Style.space(8)
                  text: modelData.name + "  " + modelData.label
                  color: root.dimForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Text {
                  id: sensorValue
                  anchors.right: parent.right
                  text: Model.formatTemperature(modelData.value) + "C"
                  color: root.levelColor(Model.temperatureLevel(modelData.value))
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Storage: capacity first, then what the disks are doing
          //      right now.
          PanelSectionHeader {
            text: "STORAGE"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Repeater {
            model: root.stats ? root.stats.filesystems : []

            Meter {
              required property var modelData

              width: column.width
              label: modelData.mount
              value: Model.formatBytesLong(modelData.used) + " / " + Model.formatBytesLong(modelData.size)
              percent: modelData.percent
              level: Model.diskLevel(modelData.percent)
              labelWidth: Style.space(120)
              valueWidth: Style.space(150)
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }
          }

          Text {
            width: parent.width
            text: "↓ " + Model.formatRate(root.stats ? root.stats.diskRead : 0)
              + "   ↑ " + Model.formatRate(root.stats ? root.stats.diskWrite : 0)
              + (root.stats && root.stats.diskDevices.length > 0
                ? "   ·   " + root.stats.diskDevices.map(function(device) { return device.name }).join(" ")
                : "")
            color: root.fainterForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Network
          PanelSectionHeader {
            text: "NETWORK"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Item {
            width: parent.width
            height: netTotals.implicitHeight

            Text {
              id: netTotals
              text: "↓ " + Model.formatRate(root.stats ? root.stats.netRx : 0)
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
            }

            Text {
              anchors.right: parent.right
              text: "↑ " + Model.formatRate(root.stats ? root.stats.netTx : 0)
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
            }
          }

          // No fixed ceiling on a rate, so the strip scales to the busiest
          // sample in the window. Download is the solid line, upload the
          // second one behind it.
          Sparkline {
            width: parent.width
            height: root.sparklineHeight
            values: root.stats ? root.stats.netRxHistory : []
            secondaryValues: root.stats ? root.stats.netTxHistory : []
            capacity: root.stats ? root.stats.historyLength : 90
            stroke: Style.selectedStateColor(root.contentForeground, Color.accent)
            secondaryStroke: Qt.darker(root.contentForeground, 1.6)
            maxValue: 0
            minimumScale: 64 * 1024
          }

          Repeater {
            model: root.stats ? root.stats.netInterfaces : []

            Item {
              required property var modelData

              width: column.width
              height: interfaceName.implicitHeight + Style.space(2)
              // Loopback and virtual interfaces stay in the list — a VPN
              // carrying all the traffic is worth seeing — but they are
              // dimmed, since they are not what "the network" means.
              opacity: modelData.physical ? 1 : 0.55

              Text {
                id: interfaceName
                anchors.left: parent.left
                text: modelData.name
                color: root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.right: parent.right
                text: "↓" + Model.formatRate(modelData.rx) + "   ↑" + Model.formatRate(modelData.tx)
                  + "   ·   " + Model.formatBytesLong(modelData.totalRx) + " / " + Model.formatBytesLong(modelData.totalTx)
                color: root.fainterForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Processes: the answer to "what is doing this", refreshed
          //      only while the panel is open.
          PanelSectionHeader {
            text: "TOP PROCESSES"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Repeater {
            model: root.stats ? root.stats.processes : []

            Item {
              required property var modelData

              width: column.width
              height: processName.implicitHeight + Style.space(3)

              Text {
                id: processName
                anchors.left: parent.left
                anchors.right: processCpu.left
                anchors.rightMargin: Style.space(10)
                text: modelData.name
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                id: processCpu
                anchors.right: processMem.left
                anchors.rightMargin: Style.space(14)
                width: Style.space(56)
                horizontalAlignment: Text.AlignRight
                text: Model.formatPercent(modelData.cpu, 1)
                color: root.levelColor(Model.loadLevel(modelData.cpu))
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: processMem
                anchors.right: parent.right
                width: Style.space(56)
                horizontalAlignment: Text.AlignRight
                text: Model.formatPercent(modelData.mem, 1)
                color: root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Footer: the one thing the panel cannot show is a process
          //      tree you can act on, so it points at the tool that can.
          Item {
            width: parent.width
            height: footerRow.height + Style.space(4)

            Row {
              id: footerRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(8)

              PanelActionButton {
                iconText: "\u{F04C5}"
                tooltipText: "Open btop"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: {
                  if (root.bar) root.bar.run("omarchy-launch-tui btop")
                  root.close()
                }
              }
            }
          }
        }
      }
    }
  }
}
