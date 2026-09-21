// Pure parsing and formatting helpers for omastats.
//
// Everything here is side-effect free so the same functions run in the QML
// engine and under node for the tests in tests/. No QML imports, no I/O:
// the QML side reads /proc, /sys, and the helper processes, and hands the
// raw text in here.

// ---- /proc/stat -------------------------------------------------------
// Returns { total: sample, cores: [sample, ...] } where a sample is
// { idle, total } in jiffies. iowait counts as idle: a core waiting on the
// disk is not a core doing work, and counting it as busy makes every I/O
// burst look like a CPU spike.
function parseProcStat(text) {
  var lines = String(text || "").split("\n")
  var total = null
  var cores = []

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.substring(0, 3) !== "cpu") continue

    var parts = line.trim().split(/\s+/)
    var name = parts[0]
    var idle = 0
    var sum = 0
    for (var f = 1; f < parts.length; f++) {
      var value = Number(parts[f])
      if (!isFinite(value)) continue
      sum += value
      // fields: user nice system idle iowait irq softirq steal ...
      if (f === 4 || f === 5) idle += value
    }

    var sample = { idle: idle, total: sum }
    if (name === "cpu") total = sample
    else cores.push(sample)
  }

  return { total: total, cores: cores }
}

// Busy percentage between two parseProcStat samples. A missing or
// non-advancing pair reads as 0 rather than as a divide-by-zero spike.
function cpuBusyPercent(previous, current) {
  if (!previous || !current) return 0
  var totalDelta = current.total - previous.total
  var idleDelta = current.idle - previous.idle
  if (!(totalDelta > 0)) return 0
  return clampPercent(((totalDelta - idleDelta) / totalDelta) * 100)
}

function cpuCorePercents(previous, current) {
  if (!previous || !current) return []
  var out = []
  var count = Math.min(previous.length, current.length)
  for (var i = 0; i < count; i++) out.push(cpuBusyPercent(previous[i], current[i]))
  return out
}

// ---- /proc/meminfo ----------------------------------------------------
// Values in the file are kB; everything below is bytes so the formatters
// only ever deal in one unit.
function parseMeminfo(text) {
  var values = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^([A-Za-z_()0-9]+):\s+(\d+)/)
    if (match) values[match[1]] = Number(match[2]) * 1024
  }

  var memTotal = values.MemTotal || 0
  // MemAvailable is the kernel's own estimate of what a new allocation
  // could get, cache included. MemFree alone would read as "97% used" on
  // any machine that has been up an hour.
  var available = values.MemAvailable !== undefined
    ? values.MemAvailable
    : (values.MemFree || 0) + (values.Buffers || 0) + (values.Cached || 0)
  var swapTotal = values.SwapTotal || 0
  var swapFree = values.SwapFree || 0

  return {
    total: memTotal,
    available: available,
    used: Math.max(0, memTotal - available),
    free: values.MemFree || 0,
    buffers: values.Buffers || 0,
    cached: (values.Cached || 0) + (values.SReclaimable || 0),
    percent: memTotal > 0 ? clampPercent(((memTotal - available) / memTotal) * 100) : 0,
    swapTotal: swapTotal,
    swapUsed: Math.max(0, swapTotal - swapFree),
    swapPercent: swapTotal > 0 ? clampPercent(((swapTotal - swapFree) / swapTotal) * 100) : 0
  }
}

// ---- /proc/net/dev ----------------------------------------------------
var VIRTUAL_INTERFACE = /^(lo|veth|docker|br-|virbr|vmnet|tun|tap|wg|zt|tailscale|podman|cni|flannel|kube)/

function isPhysicalInterface(name) {
  return !VIRTUAL_INTERFACE.test(String(name || ""))
}

// { interfaces: { name: { rx, tx } }, rx, tx } — the totals cover physical
// interfaces only, so a docker bridge copying a container image does not
// show up as internet traffic in the bar.
function parseNetDev(text) {
  var lines = String(text || "").split("\n")
  var interfaces = {}
  var rx = 0
  var tx = 0

  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*([^:\s]+):\s*(.+)$/)
    if (!match) continue

    var name = match[1]
    var fields = match[2].trim().split(/\s+/).map(Number)
    if (fields.length < 9) continue

    var entry = { rx: fields[0] || 0, tx: fields[8] || 0 }
    interfaces[name] = entry
    if (isPhysicalInterface(name)) {
      rx += entry.rx
      tx += entry.tx
    }
  }

  return { interfaces: interfaces, rx: rx, tx: tx }
}

// Bytes/second between two counter reads. Counter resets (interface down,
// 32-bit wrap) read as 0 instead of as an implausible burst.
function rate(previousValue, currentValue, seconds) {
  if (!(seconds > 0)) return 0
  var delta = Number(currentValue) - Number(previousValue)
  if (!isFinite(delta) || delta < 0) return 0
  return delta / seconds
}

function netRates(previous, current, seconds) {
  if (!previous || !current) return { rx: 0, tx: 0, interfaces: {} }

  var perInterface = {}
  for (var name in current.interfaces) {
    if (!previous.interfaces[name]) continue
    perInterface[name] = {
      rx: rate(previous.interfaces[name].rx, current.interfaces[name].rx, seconds),
      tx: rate(previous.interfaces[name].tx, current.interfaces[name].tx, seconds),
      totalRx: current.interfaces[name].rx,
      totalTx: current.interfaces[name].tx,
      physical: isPhysicalInterface(name)
    }
  }

  return {
    rx: rate(previous.rx, current.rx, seconds),
    tx: rate(previous.tx, current.tx, seconds),
    interfaces: perInterface
  }
}

// ---- /proc/diskstats --------------------------------------------------
var PHYSICAL_DISK = /^(nvme\d+n\d+|sd[a-z]+|hd[a-z]+|vd[a-z]+|mmcblk\d+)$/
var SECTOR_BYTES = 512

function parseDiskstats(text) {
  var lines = String(text || "").split("\n")
  var disks = {}

  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(/\s+/)
    if (parts.length < 10) continue

    var name = parts[2]
    if (!PHYSICAL_DISK.test(name)) continue

    disks[name] = {
      read: Number(parts[5]) * SECTOR_BYTES,
      written: Number(parts[9]) * SECTOR_BYTES
    }
  }

  return disks
}

function diskRates(previous, current, seconds) {
  var out = { disks: {}, read: 0, written: 0 }
  if (!previous || !current) return out

  for (var name in current) {
    if (!previous[name]) continue
    var entry = {
      read: rate(previous[name].read, current[name].read, seconds),
      written: rate(previous[name].written, current[name].written, seconds)
    }
    out.disks[name] = entry
    out.read += entry.read
    out.written += entry.written
  }

  return out
}

// ---- misc /proc -------------------------------------------------------
function parseLoadavg(text) {
  var parts = String(text || "").trim().split(/\s+/)
  return {
    one: Number(parts[0]) || 0,
    five: Number(parts[1]) || 0,
    fifteen: Number(parts[2]) || 0,
    running: String(parts[3] || "")
  }
}

function parseUptimeSeconds(text) {
  return Number(String(text || "").trim().split(/\s+/)[0]) || 0
}

// Per-core current clock, in MHz. Read from /proc/cpuinfo rather than from
// the per-core cpufreq sysfs files: one read instead of one per core, and
// it works on machines without a cpufreq driver.
function parseCpuMhz(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^cpu MHz\s*:\s*([\d.]+)/)
    if (match) out.push(Number(match[1]))
  }
  return out
}

function parseCpuModel(text) {
  var match = String(text || "").match(/^model name\s*:\s*(.+)$/m)
  return match ? match[1].trim() : ""
}

function averageMhz(values) {
  if (!values || !values.length) return 0
  var sum = 0
  for (var i = 0; i < values.length; i++) sum += values[i]
  return sum / values.length
}

// ---- hwmon ------------------------------------------------------------
// temp*_input is millidegrees Celsius.
function parseTemperature(text) {
  var raw = String(text || "").trim()
  if (raw === "") return NaN
  var value = Number(raw)
  if (!isFinite(value)) return NaN
  return value / 1000
}

// Chip names as the kernel reports them are not what anyone calls the part.
function friendlyChipName(chip) {
  var name = String(chip || "").trim()
  var known = {
    "coretemp": "CPU",
    "k10temp": "CPU",
    "zenpower": "CPU",
    "cpu_thermal": "CPU",
    "acpitz": "Mainboard",
    "nvme": "NVMe",
    "amdgpu": "GPU",
    "nouveau": "GPU",
    "iwlwifi": "Wi-Fi",
    "pch_": "PCH"
  }
  for (var key in known) {
    if (name.indexOf(key) === 0) return known[key]
  }
  return name
}

// The one temperature the bar and the CPU section quote. Package/Tdie beats
// a single core, and a CPU chip beats the mainboard's ACPI zone.
function pickCpuTemperature(sensors) {
  if (!sensors || !sensors.length) return null

  var best = null
  var bestScore = -1
  for (var i = 0; i < sensors.length; i++) {
    var sensor = sensors[i]
    if (!sensor || !isFinite(sensor.value)) continue

    var chip = String(sensor.chip || "")
    var label = String(sensor.label || "")
    var score = 0
    if (/^(coretemp|k10temp|zenpower|cpu_thermal)/.test(chip)) score += 10
    if (/package|tdie|tctl/i.test(label)) score += 5
    if (/^core \d+/i.test(label)) score += 1
    if (/^acpitz/.test(chip)) score += 2
    if (score > bestScore) {
      bestScore = score
      best = sensor
    }
  }

  return bestScore > 0 ? best : null
}

function sortSensors(sensors) {
  return (sensors || []).slice().sort(function(a, b) {
    var chip = String(a.chip).localeCompare(String(b.chip))
    return chip !== 0 ? chip : String(a.label).localeCompare(String(b.label))
  })
}

// ---- nvidia-smi -------------------------------------------------------
// One CSV line per GPU per sample, from
//   --query-gpu=name,utilization.gpu,temperature.gpu,memory.used,
//               memory.total,power.draw,clocks.gr,fan.speed
//   --format=csv,noheader,nounits
// Unsupported fields come back as "[N/A]" and end up NaN, which the panel
// renders as a dash rather than as a zero.
function parseNvidiaLine(line) {
  var parts = String(line || "").split(",")
  if (parts.length < 5) return null

  function number(index) {
    var value = Number(String(parts[index] || "").trim())
    return isFinite(value) ? value : NaN
  }

  var memUsed = number(3)
  var memTotal = number(4)

  return {
    vendor: "nvidia",
    name: String(parts[0] || "").trim(),
    utilization: number(1),
    temperature: number(2),
    // nvidia-smi reports MiB.
    memoryUsed: isFinite(memUsed) ? memUsed * 1024 * 1024 : NaN,
    memoryTotal: isFinite(memTotal) ? memTotal * 1024 * 1024 : NaN,
    memoryPercent: isFinite(memUsed) && memTotal > 0 ? clampPercent((memUsed / memTotal) * 100) : NaN,
    power: number(5),
    clockMhz: number(6),
    fanPercent: number(7)
  }
}

// intel_gpu_top emits an open JSON array, flushed one object at a time.
// Extract complete objects without waiting for the closing array bracket.
function readJsonObjects(text) {
  var objects = []
  var start = -1
  var depth = 0
  var quoted = false
  var escaped = false
  for (var i = 0; i < text.length; i++) {
    var ch = text[i]
    if (start < 0) {
      if (ch !== "{") continue
      start = i
    }
    if (quoted) {
      if (escaped) escaped = false
      else if (ch === "\\") escaped = true
      else if (ch === '"') quoted = false
    } else if (ch === '"') quoted = true
    else if (ch === "{") depth++
    else if (ch === "}") {
      depth--
      if (depth === 0) {
        try { objects.push(JSON.parse(text.slice(start, i + 1))) } catch (e) {}
        start = -1
      }
    }
  }
  // Bound memory if a broken helper never finishes an object.
  var remainder = start >= 0 ? text.slice(start) : ""
  return { objects: objects, remainder: remainder.length <= 1048576 ? remainder : "" }
}

function parseIntelGpuSample(sample) {
  if (!sample || !sample.engines) return null
  // Engines run concurrently. Use the busiest engine, not their sum, so
  // video decoding counts too and simultaneous work cannot exceed 100%.
  var utilization = NaN
  for (var name in sample.engines) {
    var engine = sample.engines[name]
    if (!engine || typeof engine.busy !== "number" || !isFinite(engine.busy)) continue
    utilization = Math.max(isFinite(utilization) ? utilization : 0, clampPercent(engine.busy))
  }
  if (!isFinite(utilization)) return null
  return { utilization: utilization }
}

// ---- helper output ----------------------------------------------------
// `df -B1 --output=source,target,size,used,avail,pcent`, header dropped.
// The four numeric columns are read from the right and the device from the
// left, so a mount point containing spaces stays in one piece.
//
// One row per filesystem, not per mount point: btrfs subvolumes and bind
// mounts all report their shared filesystem's numbers, and listing /,
// /home, /var/log and /var/cache with identical bars says nothing. The
// shallowest mount point wins, with / preferred outright.
function parseDf(text) {
  var lines = String(text || "").trim().split("\n")
  var byDevice = {}
  var out = []

  for (var i = 1; i < lines.length; i++) {
    var parts = lines[i].trim().split(/\s+/)
    if (parts.length < 6) continue

    var percent = Number(String(parts[parts.length - 1]).replace("%", ""))
    var available = Number(parts[parts.length - 2])
    var used = Number(parts[parts.length - 3])
    var size = Number(parts[parts.length - 4])
    var source = parts[0]
    var target = parts.slice(1, parts.length - 4).join(" ")
    if (!(size > 0)) continue

    var row = {
      device: source,
      mount: target,
      size: size,
      used: used,
      available: available,
      percent: isFinite(percent) ? percent : clampPercent((used / size) * 100)
    }

    var existing = byDevice[source];
    if (existing) {
      if (existing.mount === "/") continue
      if (target !== "/" && target.split("/").length >= existing.mount.split("/").length) continue
      out[out.indexOf(existing)] = row
      byDevice[source] = row
      continue
    }

    byDevice[source] = row
    out.push(row)
  }

  return out.sort(function(a, b) {
    if (a.mount === "/") return -1
    if (b.mount === "/") return 1
    return b.size - a.size
  })
}

// `ps -eo pid=,pcpu=,pmem=,comm=` — command last, so a comm with spaces
// stays in one piece.
function parseProcesses(text, limit) {
  var lines = String(text || "").trim().split("\n")
  var out = []

  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(/\s+/)
    if (parts.length < 4) continue

    var pid = Number(parts[0])
    var cpu = Number(parts[1])
    var mem = Number(parts[2])
    if (!isFinite(pid)) continue

    out.push({
      pid: pid,
      cpu: isFinite(cpu) ? cpu : 0,
      mem: isFinite(mem) ? mem : 0,
      name: parts.slice(3).join(" ")
    })
  }

  out.sort(function(a, b) { return b.cpu - a.cpu })
  return limit > 0 ? out.slice(0, limit) : out
}

// ---- history ----------------------------------------------------------
// Ring buffers as plain arrays. Returned as a new array: QML only sees a
// var property change when the reference changes, so mutating in place
// would leave every sparkline bound to it frozen.
function pushHistory(history, value, capacity) {
  var next = (history || []).slice()
  next.push(isFinite(value) ? value : 0)
  var max = capacity > 0 ? capacity : 60
  if (next.length > max) next = next.slice(next.length - max)
  return next
}

function historyMax(history, floor) {
  var max = floor > 0 ? floor : 0
  for (var i = 0; i < (history || []).length; i++) {
    if (history[i] > max) max = history[i]
  }
  return max
}

// ---- formatting -------------------------------------------------------
function clampPercent(value) {
  if (!isFinite(value)) return 0
  return Math.max(0, Math.min(100, value))
}

function formatPercent(value, decimals) {
  if (!isFinite(value)) return "—"
  return value.toFixed(decimals > 0 ? decimals : 0) + "%"
}

var BYTE_UNITS = ["B", "K", "M", "G", "T", "P"]

// Compact by design: this goes in a bar label where every character costs
// horizontal space. formatBytesLong is the panel's version.
function formatBytes(bytes, decimals) {
  if (!isFinite(bytes)) return "—"

  var value = Math.abs(Number(bytes))
  var unit = 0
  while (value >= 1024 && unit < BYTE_UNITS.length - 1) {
    value /= 1024
    unit++
  }

  var places = decimals !== undefined && decimals !== null
    ? decimals
    : (unit === 0 ? 0 : (value < 10 ? 1 : 0))
  return value.toFixed(places) + BYTE_UNITS[unit]
}

function formatBytesLong(bytes) {
  if (!isFinite(bytes)) return "—"

  var value = Math.abs(Number(bytes))
  var unit = 0
  while (value >= 1024 && unit < BYTE_UNITS.length - 1) {
    value /= 1024
    unit++
  }

  var names = ["B", "KB", "MB", "GB", "TB", "PB"]
  return value.toFixed(unit === 0 || value >= 10 ? 0 : 1) + " " + names[unit]
}

function formatRate(bytesPerSecond) {
  return formatBytes(bytesPerSecond) + "/s"
}

function formatTemperature(celsius) {
  if (!isFinite(celsius)) return "—"
  return Math.round(celsius) + "°"
}

function formatMhz(mhz) {
  if (!isFinite(mhz) || mhz <= 0) return "—"
  if (mhz >= 1000) return (mhz / 1000).toFixed(2) + " GHz"
  return Math.round(mhz) + " MHz"
}

function formatUptime(seconds) {
  var total = Math.max(0, Math.floor(Number(seconds) || 0))
  var days = Math.floor(total / 86400)
  var hours = Math.floor((total % 86400) / 3600)
  var minutes = Math.floor((total % 3600) / 60)

  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  return minutes + "m"
}

// ---- severity ---------------------------------------------------------
// Three levels, so the panel and the bar agree on when a number stops being
// ordinary. Thresholds differ per metric: 80°C is hot for a CPU, 80% is
// ordinary for a filling disk.
function level(value, warn, critical) {
  if (!isFinite(value)) return "normal"
  if (value >= critical) return "critical"
  if (value >= warn) return "warn"
  return "normal"
}

function loadLevel(percent) { return level(percent, 75, 92) }
function temperatureLevel(celsius) { return level(celsius, 75, 88) }
function diskLevel(percent) { return level(percent, 85, 95) }

// ---- bar label --------------------------------------------------------
// The bar shows a chosen subset; the panel always shows everything. Keys
// here are what shell.json stores in the widget entry's `metrics` array.
var METRIC_KEYS = ["cpu", "cpuTemp", "mem", "swap", "gpu", "gpuTemp", "net", "disk"]

// Material Design glyphs from the Nerd Font the bar already uses.
var METRIC_ICONS = {
  cpu: "\u{F061A}",
  cpuTemp: "\u{F050F}",
  mem: "\u{F035B}",
  swap: "\u{F04E6}",
  gpu: "\u{F0379}",
  gpuTemp: "\u{F050F}",
  net: "\u{F0318}",
  disk: "\u{F02CA}"
}

function metricNeedsGpu(metrics) {
  var list = metrics || []
  return list.indexOf("gpu") >= 0 || list.indexOf("gpuTemp") >= 0
}

function normalizeMetrics(value, fallback) {
  var requested = Array.isArray(value) ? value : String(value || "").split(/[\s,]+/)
  var out = []
  for (var i = 0; i < requested.length; i++) {
    var key = String(requested[i] || "").trim()
    if (METRIC_KEYS.indexOf(key) >= 0 && out.indexOf(key) < 0) out.push(key)
  }
  return out.length ? out : (fallback || ["cpu", "mem", "net"])
}

// One entry per metric the bar is configured to show, in the configured
// order. Each carries its own level so a hot CPU can color its own segment
// without the rest of the label changing.
//
// `snapshot` is a plain object so this stays testable without a QML engine:
// { cpu, cpuTemperature, memory, gpu, netRx, netTx, diskRead, diskWrite }.
function barSegments(metrics, snapshot, showIcons) {
  var keys = normalizeMetrics(metrics)
  var data = snapshot || {}
  var memory = data.memory || {}
  var gpu = data.gpu || null
  var out = []

  function push(key, text, severity) {
    out.push({
      key: key,
      icon: METRIC_ICONS[key] || "",
      text: text,
      level: severity || "normal",
      label: (showIcons === false ? "" : (METRIC_ICONS[key] ? METRIC_ICONS[key] + " " : "")) + text
    })
  }

  for (var i = 0; i < keys.length; i++) {
    var key = keys[i]

    if (key === "cpu") {
      push(key, formatPercent(data.cpu), loadLevel(data.cpu))
    } else if (key === "cpuTemp") {
      var temperature = data.cpuTemperature
      if (isFinite(temperature)) push(key, formatTemperature(temperature), temperatureLevel(temperature))
    } else if (key === "mem") {
      push(key, formatPercent(memory.percent), loadLevel(memory.percent))
    } else if (key === "swap") {
      // A machine with swap off would otherwise carry a permanent "0%".
      if (memory.swapTotal > 0) push(key, formatPercent(memory.swapPercent), loadLevel(memory.swapPercent))
    } else if (key === "gpu") {
      if (gpu && isFinite(gpu.utilization)) push(key, formatPercent(gpu.utilization), loadLevel(gpu.utilization))
    } else if (key === "gpuTemp") {
      if (gpu && isFinite(gpu.temperature)) push(key, formatTemperature(gpu.temperature), temperatureLevel(gpu.temperature))
    } else if (key === "net") {
      push(key, "\u2193" + formatBytes(data.netRx) + " \u2191" + formatBytes(data.netTx), "normal")
    } else if (key === "disk") {
      push(key, "\u2193" + formatBytes(data.diskRead) + " \u2191" + formatBytes(data.diskWrite), "normal")
    }
  }

  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    parseProcStat: parseProcStat,
    cpuBusyPercent: cpuBusyPercent,
    cpuCorePercents: cpuCorePercents,
    parseMeminfo: parseMeminfo,
    parseNetDev: parseNetDev,
    isPhysicalInterface: isPhysicalInterface,
    rate: rate,
    netRates: netRates,
    parseDiskstats: parseDiskstats,
    diskRates: diskRates,
    parseLoadavg: parseLoadavg,
    parseUptimeSeconds: parseUptimeSeconds,
    parseCpuMhz: parseCpuMhz,
    parseCpuModel: parseCpuModel,
    averageMhz: averageMhz,
    parseTemperature: parseTemperature,
    friendlyChipName: friendlyChipName,
    pickCpuTemperature: pickCpuTemperature,
    sortSensors: sortSensors,
    parseNvidiaLine: parseNvidiaLine,
    readJsonObjects: readJsonObjects,
    parseIntelGpuSample: parseIntelGpuSample,
    parseDf: parseDf,
    parseProcesses: parseProcesses,
    pushHistory: pushHistory,
    historyMax: historyMax,
    clampPercent: clampPercent,
    formatPercent: formatPercent,
    formatBytes: formatBytes,
    formatBytesLong: formatBytesLong,
    formatRate: formatRate,
    formatTemperature: formatTemperature,
    formatMhz: formatMhz,
    formatUptime: formatUptime,
    level: level,
    loadLevel: loadLevel,
    temperatureLevel: temperatureLevel,
    diskLevel: diskLevel,
    METRIC_KEYS: METRIC_KEYS,
    METRIC_ICONS: METRIC_ICONS,
    metricNeedsGpu: metricNeedsGpu,
    normalizeMetrics: normalizeMetrics,
    barSegments: barSegments
  }
}
