import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The sampler. Everything the bar widget and the panel display is read here
// and nowhere else.
//
// Reads come straight from /proc and /sys through FileView, inside the
// shell process — no subprocess per tick. The things the kernel does
// not hand over as a plain readable file get a helper:
//
//   bin/omastats-sensors  one shot at startup, to find the hwmon files
//   bin/omastats-gpu      long-lived, only while a GPU number is on screen
//   bin/omastats-igpu     Intel iGPU and package watts, panel only
//   df / ps               only while the panel is open
//
// Consumers announce what they need with retain()/release() so a closed
// panel costs nothing: the base tick keeps running for the bar label, the
// rest stays off.
Item {
  id: root
  visible: false

  // The plugin is installed as a folder; scripts sit next to the QML. The
  // URL is percent-encoded, so a home directory with a space in it would
  // otherwise hand Process a path that does not exist.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))

  property int interval: 1000
  property int sensorInterval: 2000
  property int gpuInterval: 2000
  property int detailInterval: 3000
  property int historyLength: 90

  // Reference counts, one per class of work. A widget on each monitor means
  // several consumers of the same sampler; the work is done once either way.
  property int subscribers: 0
  property int detailSubscribers: 0
  property int gpuSubscribers: 0

  readonly property bool sampling: subscribers > 0
  readonly property bool detailed: detailSubscribers > 0
  readonly property bool gpuActive: gpuSubscribers > 0 && gpuAvailable

  // Set false after the helper exits without ever printing a line, so a
  // machine with no supported GPU stops respawning it.
  property bool gpuAvailable: true

  function retain(kind) { adjust(kind, 1) }
  function release(kind) { adjust(kind, -1) }

  function adjust(kind, delta) {
    if (kind === "detail") detailSubscribers = Math.max(0, detailSubscribers + delta)
    else if (kind === "gpu") gpuSubscribers = Math.max(0, gpuSubscribers + delta)
    else subscribers = Math.max(0, subscribers + delta)
  }

  // ---- CPU
  property real cpuPercent: 0
  property var cpuCores: []
  property real cpuMhz: 0
  property string cpuModel: ""
  property int coreCount: 0
  property var loadAverage: ({ one: 0, five: 0, fifteen: 0, running: "" })
  property real uptimeSeconds: 0

  // Socket power, from the iGPU helper — so it exists only while the panel
  // is open, and only on an Intel machine with intel-gpu-tools. It covers
  // the whole package, iGPU included, which is why it is not called "CPU".
  property real packageWatts: NaN

  // ---- Memory
  property var memory: ({ total: 0, used: 0, available: 0, cached: 0, percent: 0, swapTotal: 0, swapUsed: 0, swapPercent: 0 })

  // ---- Network
  property real netRx: 0
  property real netTx: 0
  property var netInterfaces: []

  // ---- Disk
  property real diskRead: 0
  property real diskWrite: 0
  property var diskDevices: []
  property var filesystems: []

  // ---- Sensors
  property var sensors: []
  property var cpuTemperatureSensor: null
  readonly property real cpuTemperature: cpuTemperatureSensor ? cpuTemperatureSensor.value : NaN

  // ---- GPU
  property var gpu: null
  property bool igpuDetected: false
  property bool igpuAvailable: true
  property real igpuPercent: NaN
  property real igpuWatts: NaN
  property string igpuError: ""
  property string igpuBuffer: ""

  // ---- Processes
  property var processes: []

  // ---- History rings, oldest first
  property var cpuHistory: []
  property var memHistory: []
  property var netRxHistory: []
  property var netTxHistory: []
  property var gpuHistory: []
  property var gpuWattsHistory: []
  property var igpuHistory: []
  property var igpuWattsHistory: []
  property var packageWattsHistory: []
  property var cpuTemperatureHistory: []

  signal sensorTick()

  // Bumped once per sensor tick. The history push is keyed to it so a
  // rebuild triggered by each individual file landing does not push a dozen
  // samples for one round of readings.
  property int sensorSerial: 0
  property int sensorHistorySerial: -1

  // Previous counter reads. Rates are deltas over the time actually elapsed
  // between two reads, not over the nominal interval — a shell busy enough
  // to run late would otherwise overstate every rate.
  property var previousCpu: null
  property var previousCores: null
  property real previousCpuTime: 0
  property var previousNet: null
  property real previousNetTime: 0
  property var previousDisk: null
  property real previousDiskTime: 0

  function scriptPath(name) {
    return pluginDir + "/bin/" + name
  }

  function tick() {
    cpuStatFile.reload()
    memoryFile.reload()
    networkFile.reload()
    diskFile.reload()
    loadFile.reload()
    uptimeFile.reload()
    cpuInfoFile.reload()
  }

  function applyCpuStat(text) {
    var parsed = Model.parseProcStat(text)
    var now = Date.now()

    if (parsed.total && previousCpu) {
      cpuPercent = Model.cpuBusyPercent(previousCpu, parsed.total)
      cpuCores = Model.cpuCorePercents(previousCores, parsed.cores)
      cpuHistory = Model.pushHistory(cpuHistory, cpuPercent, historyLength)
    }

    coreCount = parsed.cores.length
    previousCpu = parsed.total
    previousCores = parsed.cores
    previousCpuTime = now
  }

  function applyMemory(text) {
    memory = Model.parseMeminfo(text)
    memHistory = Model.pushHistory(memHistory, memory.percent, historyLength)
  }

  function applyNetwork(text) {
    var parsed = Model.parseNetDev(text)
    var now = Date.now()

    if (previousNet && previousNetTime > 0) {
      var rates = Model.netRates(previousNet, parsed, (now - previousNetTime) / 1000)
      netRx = rates.rx
      netTx = rates.tx
      netRxHistory = Model.pushHistory(netRxHistory, netRx, historyLength)
      netTxHistory = Model.pushHistory(netTxHistory, netTx, historyLength)

      var list = []
      for (var name in rates.interfaces) {
        var entry = rates.interfaces[name]
        list.push({
          name: name,
          rx: entry.rx,
          tx: entry.tx,
          totalRx: entry.totalRx,
          totalTx: entry.totalTx,
          physical: entry.physical
        })
      }
      // Busiest first, so the interface actually carrying traffic is the one
      // at the top of the panel's list whichever way it is named.
      list.sort(function(a, b) { return (b.rx + b.tx) - (a.rx + a.tx) })
      netInterfaces = list
    }

    previousNet = parsed
    previousNetTime = now
  }

  function applyDisk(text) {
    var parsed = Model.parseDiskstats(text)
    var now = Date.now()

    if (previousDisk && previousDiskTime > 0) {
      var rates = Model.diskRates(previousDisk, parsed, (now - previousDiskTime) / 1000)
      diskRead = rates.read
      diskWrite = rates.written

      var list = []
      for (var name in rates.disks) {
        list.push({ name: name, read: rates.disks[name].read, written: rates.disks[name].written })
      }
      list.sort(function(a, b) { return (b.read + b.written) - (a.read + a.written) })
      diskDevices = list
    }

    previousDisk = parsed
    previousDiskTime = now
  }

  function applyCpuInfo(text) {
    cpuMhz = Model.averageMhz(Model.parseCpuMhz(text))
    if (cpuModel === "") cpuModel = Model.parseCpuModel(text)
  }

  // ---- Sensors. The helper lists them once; the values come from plain
  //      file reads on the slower sensor tick.
  property var sensorDescriptors: []
  property var sensorValues: ({})

  function applySensorList(text) {
    var list = []
    try {
      list = JSON.parse(String(text || "[]"))
    } catch (error) {
      console.warn("omastats: sensor list is not JSON:", error)
      list = []
    }
    sensorDescriptors = Array.isArray(list) ? list : []
    rebuildSensors()
  }

  function setSensorValue(key, value) {
    sensorValues[key] = value
    rebuildSensorsLater()
  }

  property bool sensorRebuildQueued: false

  // Every sensor file lands its own onLoaded, so a rebuild per file would
  // rebuild the list a dozen times per tick. One rebuild per event loop
  // pass instead.
  function rebuildSensorsLater() {
    if (sensorRebuildQueued) return
    sensorRebuildQueued = true
    Qt.callLater(function() {
      sensorRebuildQueued = false
      rebuildSensors()
    })
  }

  function rebuildSensors() {
    var list = []
    for (var i = 0; i < sensorDescriptors.length; i++) {
      var descriptor = sensorDescriptors[i]
      var value = sensorValues[descriptor.path]
      if (value === undefined || !isFinite(value)) continue

      list.push({
        path: descriptor.path,
        chip: descriptor.chip,
        name: Model.friendlyChipName(descriptor.chip),
        label: descriptor.label,
        value: value
      })
    }

    sensors = Model.sortSensors(list)
    var cpuSensor = Model.pickCpuTemperature(sensors)
    cpuTemperatureSensor = cpuSensor
    if (cpuSensor && sensorHistorySerial !== sensorSerial) {
      sensorHistorySerial = sensorSerial
      cpuTemperatureHistory = Model.pushHistory(cpuTemperatureHistory, cpuSensor.value, historyLength)
    }
  }

  // ---- GPU
  function applyGpuLine(line) {
    var parsed = Model.parseNvidiaLine(line)
    if (!parsed) return
    gpu = parsed
    gpuHistory = Model.pushHistory(gpuHistory, parsed.utilization, historyLength)
    if (isFinite(parsed.power)) gpuWattsHistory = Model.pushHistory(gpuWattsHistory, parsed.power, historyLength)
  }

  function applyIgpuLine(line) {
    // intel_gpu_top indents everything nested inside a sample, so only an
    // unindented line can close one. Rescanning the buffer on every line
    // made each sample cost O(lines²) — ~50ms of GUI thread per sample.
    igpuBuffer += line + "\n"
    // The length check keeps readJsonObjects' memory bound in force.
    if (/^\s/.test(line) && igpuBuffer.length < 1048576) return
    var decoded = Model.readJsonObjects(igpuBuffer)
    igpuBuffer = decoded.remainder
    for (var i = 0; i < decoded.objects.length; i++) {
      var object = decoded.objects[i]
      if (object.detected) igpuDetected = true
      if (object.error) igpuError = object.error
      var sample = Model.parseIntelGpuSample(object)
      if (!sample) continue
      igpuPercent = sample.utilization
      igpuError = ""
      igpuHistory = Model.pushHistory(igpuHistory, igpuPercent, historyLength)

      // A machine whose firmware does not report power leaves these NaN
      // for the whole session; the panel drops their rows rather than
      // showing a permanent dash.
      igpuWatts = sample.watts
      if (isFinite(igpuWatts)) igpuWattsHistory = Model.pushHistory(igpuWattsHistory, igpuWatts, historyLength)
      packageWatts = sample.packageWatts
      if (isFinite(packageWatts)) packageWattsHistory = Model.pushHistory(packageWattsHistory, packageWatts, historyLength)
    }
  }

  // ---- Panel-only extras
  function applyFilesystems(text) {
    filesystems = Model.parseDf(text)
  }

  function applyProcesses(text) {
    processes = Model.parseProcesses(text, 8)
  }

  FileView {
    id: cpuStatFile
    path: "/proc/stat"
    printErrors: false
    onLoaded: root.applyCpuStat(text())
  }

  FileView {
    id: memoryFile
    path: "/proc/meminfo"
    printErrors: false
    onLoaded: root.applyMemory(text())
  }

  FileView {
    id: networkFile
    path: "/proc/net/dev"
    printErrors: false
    onLoaded: root.applyNetwork(text())
  }

  FileView {
    id: diskFile
    path: "/proc/diskstats"
    printErrors: false
    onLoaded: root.applyDisk(text())
  }

  FileView {
    id: loadFile
    path: "/proc/loadavg"
    printErrors: false
    onLoaded: root.loadAverage = Model.parseLoadavg(text())
  }

  FileView {
    id: uptimeFile
    path: "/proc/uptime"
    printErrors: false
    onLoaded: root.uptimeSeconds = Model.parseUptimeSeconds(text())
  }

  FileView {
    id: cpuInfoFile
    path: "/proc/cpuinfo"
    printErrors: false
    onLoaded: root.applyCpuInfo(text())
  }

  // One FileView per discovered sensor, reloaded on the sensor tick. Kept
  // out of the main tick because a package temperature does not move fast
  // enough to be worth reading every second.
  Instantiator {
    model: root.sensorDescriptors

    delegate: Item {
      required property var modelData

      FileView {
        id: sensorFile
        path: modelData.path
        printErrors: false
        onLoaded: root.setSensorValue(modelData.path, Model.parseTemperature(text()))
      }

      Connections {
        target: root
        function onSensorTick() { sensorFile.reload() }
      }
    }
  }

  Process {
    id: sensorListProcess
    command: [root.scriptPath("omastats-sensors")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySensorList(text)
    }
  }

  Process {
    id: gpuProcess
    running: root.gpuActive
    command: [root.scriptPath("omastats-gpu"), String(Math.max(1, Math.round(root.gpuInterval / 1000)))]
    stdout: SplitParser {
      onRead: function(line) { root.applyGpuLine(line) }
    }
    // The helper exits immediately on a machine with no GPU it can read.
    // Without this it would be restarted on every panel open forever.
    onExited: if (root.gpu === null) root.gpuAvailable = false
  }

  // intel_gpu_top stalls the compositor-side GPU for a few hundred ms while
  // it opens the i915 counters. Started together with the panel, that stall
  // freezes the panel's fade-in half-transparent; started once the fade has
  // finished, it lands on an already opaque panel and goes unnoticed.
  property bool igpuStartReady: false
  onDetailedChanged: if (!detailed) igpuStartReady = false

  Timer {
    interval: 200
    running: root.detailed && !root.igpuStartReady
    onTriggered: root.igpuStartReady = true
  }

  Process {
    id: igpuProcess
    running: root.detailed && root.igpuStartReady && root.igpuAvailable
    command: [root.scriptPath("omastats-igpu"), String(Math.max(250, root.gpuInterval))]
    onStarted: {
      root.igpuBuffer = ""
      root.igpuPercent = NaN
      root.igpuWatts = NaN
      root.packageWatts = NaN
    }
    stdout: SplitParser {
      onRead: function(line) { root.applyIgpuLine(line) }
    }
    onExited: {
      if (!root.detailed) return
      root.igpuAvailable = false
      root.igpuPercent = NaN
      root.igpuWatts = NaN
      root.packageWatts = NaN
      if (root.igpuDetected && !root.igpuError)
        root.igpuError = "iGPU counters unavailable. Check intel_gpu_top access and permissions."
    }
  }

  Process {
    id: filesystemProcess
    // source comes along so subvolumes of one filesystem collapse into a
    // single row instead of repeating the same numbers per mount point.
    command: ["df", "-B1", "--output=source,target,size,used,avail,pcent", "-x", "tmpfs", "-x", "devtmpfs", "-x", "efivarfs", "-x", "overlay", "-x", "squashfs"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFilesystems(text)
    }
  }

  Process {
    id: processListProcess
    command: ["ps", "-eo", "pid=,pcpu=,pmem=,comm=", "--sort=-pcpu"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProcesses(text)
    }
  }

  Timer {
    interval: root.interval
    running: root.sampling
    repeat: true
    triggeredOnStart: true
    onTriggered: root.tick()
  }

  Timer {
    interval: root.sensorInterval
    running: root.sampling
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.sensorSerial++
      root.sensorTick()
    }
  }

  Timer {
    interval: root.detailInterval
    running: root.detailed
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!filesystemProcess.running) filesystemProcess.running = true
      if (!processListProcess.running) processListProcess.running = true
    }
  }

  Component.onCompleted: sensorListProcess.running = true
}
