// Run with: node tests/model.test.mjs
// Parsers are checked against fixtures first, then against this machine's
// live /proc so a kernel that formats a file differently fails here rather
// than silently in the bar.
import { createRequire } from "node:module"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const require = createRequire(import.meta.url)
const M = require("../Model.js")

let failures = 0
function check(name, condition, detail) {
  if (condition) return
  failures++
  console.error(`FAIL ${name}${detail ? " — " + detail : ""}`)
}
function eq(name, actual, expected) {
  check(name, actual === expected, `got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`)
}
function near(name, actual, expected, tolerance = 0.001) {
  check(name, Math.abs(actual - expected) <= tolerance, `got ${actual}, want ~${expected}`)
}

// ---- /proc/stat
const statA = `cpu  100 0 100 800 0 0 0 0 0 0
cpu0 50 0 50 400 0 0 0 0 0 0
cpu1 50 0 50 400 0 0 0 0 0 0
intr 12345`
const statB = `cpu  200 0 200 1600 0 0 0 0 0 0
cpu0 150 0 150 400 0 0 0 0 0 0
cpu1 50 0 50 1200 0 0 0 0 0 0
intr 12399`
const a = M.parseProcStat(statA)
const b = M.parseProcStat(statB)
eq("stat: core count", a.cores.length, 2)
eq("stat: total jiffies", a.total.total, 1000)
eq("stat: idle counts iowait", M.parseProcStat("cpu 0 0 0 10 5 0 0 0").total.idle, 15)
// 1000 jiffies elapsed, 800 of them idle.
near("stat: overall busy 20%", M.cpuBusyPercent(a.total, b.total), 20)
const cores = M.cpuCorePercents(a.cores, b.cores)
near("stat: core0 busy 100%", cores[0], 100)
near("stat: core1 busy 0%", cores[1], 0)
eq("stat: counter reset is 0", M.cpuBusyPercent(b.total, a.total), 0)
eq("stat: missing sample is 0", M.cpuBusyPercent(null, b.total), 0)

// ---- /proc/meminfo
const mem = M.parseMeminfo(`MemTotal:       16000000 kB
MemFree:         1000000 kB
MemAvailable:    8000000 kB
Buffers:          200000 kB
Cached:          6000000 kB
SReclaimable:     500000 kB
SwapTotal:       8000000 kB
SwapFree:        6000000 kB`)
eq("meminfo: total bytes", mem.total, 16000000 * 1024)
eq("meminfo: used excludes reclaimable cache", mem.used, 8000000 * 1024)
near("meminfo: percent", mem.percent, 50)
near("meminfo: swap percent", mem.swapPercent, 25)
eq("meminfo: cached folds in SReclaimable", mem.cached, 6500000 * 1024)
eq("meminfo: no swap is 0%, not NaN", M.parseMeminfo("MemTotal: 100 kB").swapPercent, 0)

// ---- /proc/net/dev
const netText = (rx, tx, dockerRx) => `Inter-|   Receive                    |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets
    lo: 5000 10 0 0 0 0 0 0 5000 10 0 0 0 0 0 0
  eno1: ${rx} 100 0 0 0 0 0 0 ${tx} 90 0 0 0 0 0 0
docker0: ${dockerRx} 5 0 0 0 0 0 0 40 5 0 0 0 0 0 0`
const net1 = M.parseNetDev(netText(1000, 500, 10))
const net2 = M.parseNetDev(netText(3000, 1500, 999999))
eq("netdev: lo excluded from totals", net1.rx, 1000)
eq("netdev: docker excluded from totals", net2.rx, 3000)
eq("netdev: per-interface kept", net1.interfaces.lo.rx, 5000)
const rates = M.netRates(net1, net2, 2)
eq("netdev: rx rate B/s", rates.rx, 1000)
eq("netdev: tx rate B/s", rates.tx, 500)
eq("netdev: virtual flagged", rates.interfaces["docker0"].physical, false)
eq("netdev: zero interval is 0", M.netRates(net1, net2, 0).rx, 0)

// ---- diskstats
const disk1 = M.parseDiskstats(`   8       0 sda 100 0 200 0 50 0 400 0
 259       0 nvme0n1 10 0 20 0 5 0 40 0
 259       1 nvme0n1p1 10 0 20 0 5 0 40 0`)
eq("diskstats: partitions skipped", Object.keys(disk1).sort().join(","), "nvme0n1,sda")
eq("diskstats: sectors to bytes", disk1.sda.read, 200 * 512)
const disk2 = M.parseDiskstats(`   8       0 sda 100 0 300 0 50 0 400 0
 259       0 nvme0n1 10 0 20 0 5 0 40 0`)
eq("diskstats: read rate", M.diskRates(disk1, disk2, 1).read, 100 * 512)

// ---- misc /proc
eq("loadavg", M.parseLoadavg("0.52 0.58 0.59 2/1234 5678").five, 0.58)
eq("uptime", M.parseUptimeSeconds("12345.67 98765.43"), 12345.67)
eq("cpuinfo: per-core MHz", M.parseCpuMhz("cpu MHz\t\t: 3800.000\ncpu MHz\t\t: 800.000").length, 2)
near("cpuinfo: average MHz", M.averageMhz([3800, 800]), 2300)
eq("cpuinfo: model", M.parseCpuModel("processor : 0\nmodel name\t: Intel(R) Core(TM) i5-8400 CPU @ 2.80GHz"), "Intel(R) Core(TM) i5-8400 CPU @ 2.80GHz")

// ---- hwmon
eq("hwmon: millidegrees", M.parseTemperature("45000\n"), 45)
check("hwmon: garbage is NaN", Number.isNaN(M.parseTemperature("")))
eq("hwmon: chip alias", M.friendlyChipName("coretemp"), "CPU")
eq("hwmon: unknown chip kept", M.friendlyChipName("weird_chip"), "weird_chip")
const sensors = [
  { chip: "acpitz", label: "temp1", value: 40 },
  { chip: "coretemp", label: "Core 0", value: 50 },
  { chip: "coretemp", label: "Package id 0", value: 55 },
  { chip: "nvme", label: "Composite", value: 35 }
]
eq("hwmon: package wins", M.pickCpuTemperature(sensors).value, 55)
eq("hwmon: no cpu sensor is null", M.pickCpuTemperature([{ chip: "nvme", label: "Composite", value: 35 }]), null)

// ---- nvidia-smi
const gpu = M.parseNvidiaLine("NVIDIA GeForce RTX 4060, 12, 45, 512, 8188, 23.45, 210, 30")
eq("nvidia: name", gpu.name, "NVIDIA GeForce RTX 4060")
eq("nvidia: util", gpu.utilization, 12)
eq("nvidia: MiB to bytes", gpu.memoryUsed, 512 * 1024 * 1024)
near("nvidia: memory percent", gpu.memoryPercent, 6.2537, 0.001)
check("nvidia: N/A stays NaN", Number.isNaN(M.parseNvidiaLine("GPU, 1, 2, 3, 4, [N/A], 5, 6").power))
eq("nvidia: short line rejected", M.parseNvidiaLine("junk"), null)

// ---- Intel iGPU: independent samples from the streaming JSON array
const intelSample = {
  engines: {
    "Render/3D/0": { busy: 12.5 },
    "Video/0": { busy: 48.25 },
    "Blitter/0": { busy: 7 }
  }
}
near("intel: video work counts, overlapping engines are not summed", M.parseIntelGpuSample(intelSample).utilization, 48.25)
eq("intel: idle is a valid sample", M.parseIntelGpuSample({ engines: { Render: { busy: 0 } } }).utilization, 0)
eq("intel: clamp percent", M.parseIntelGpuSample({ engines: { Render: { busy: 101 } } }).utilization, 100)
eq("intel: missing engines is not idle", M.parseIntelGpuSample({}), null)
eq("intel: empty engines is not idle", M.parseIntelGpuSample({ engines: {} }), null)
eq("intel: invalid values are not idle", M.parseIntelGpuSample({ engines: { Render: { busy: null }, Video: { busy: "N/A" }, Copy: { busy: NaN } } }), null)
eq("intel: null engine ignored", M.parseIntelGpuSample({ engines: { Render: null } }), null)

// ---- Watts. intel_gpu_top reports the graphics slice and the whole socket
// separately; both ride along with the utilization sample.
const intelPowered = { engines: { Render: { busy: 10 } }, power: { GPU: 7.382133, Package: 45.491881, unit: "W" } }
near("intel: igpu watts", M.parseIntelGpuSample(intelPowered).watts, 7.382133)
near("intel: package watts", M.parseIntelGpuSample(intelPowered).packageWatts, 45.491881)
check("intel: firmware without power reports NaN", !isFinite(M.parseIntelGpuSample(intelSample).watts))
check("intel: a negative reading is not a watt", !isFinite(M.parseIntelGpuSample({ engines: { Render: { busy: 1 } }, power: { GPU: -1 } }).watts))
eq("intel: idle iGPU reports zero, not absent", M.parseIntelGpuSample({ engines: { Render: { busy: 0 } }, power: { GPU: 0 } }).watts, 0)

eq("watts: the small end keeps a decimal", M.formatWatts(7.382133), "7.4 W")
eq("watts: the large end does not", M.formatWatts(45.491881), "45 W")
eq("watts: zero is a reading", M.formatWatts(0), "0.0 W")
eq("watts: nothing to report", M.formatWatts(NaN), "\u2014")

// The track scales against the window's own peak, so a part that has never
// drawn more than a few watts still fills its meter.
eq("watts: fills against the window peak", M.wattsPercent(5, [1, 2, 5], 1), 100)
eq("watts: a floor keeps idle noise small", M.wattsPercent(1, [0.5, 1], 20), 5)
eq("watts: a fresh sample above the peak still fits", M.wattsPercent(60, [10, 20], 15), 100)
eq("watts: nothing to draw", M.wattsPercent(NaN, [1, 2], 1), 0)

const intelStream = '[\n' + JSON.stringify(intelSample, null, 2) + ',\n' + JSON.stringify({ engines: { Render: { busy: 0 } }, client: 'name {with} "quotes" and \\ escapes' })
let jsonBuffer = ""
const intelObjects = []
// Exercise arbitrary split boundaries, including strings and nested objects.
for (const ch of intelStream) {
  const decoded = M.readJsonObjects(jsonBuffer + ch)
  intelObjects.push(...decoded.objects)
  jsonBuffer = decoded.remainder
}
eq("intel: samples arrive before the stream closes", intelObjects.length, 2)
near("intel: first streamed utilization", M.parseIntelGpuSample(intelObjects[0]).utilization, 48.25)
eq("intel: second streamed utilization", M.parseIntelGpuSample(intelObjects[1]).utilization, 0)
eq("intel: no consumed data retained", jsonBuffer, "")
eq("intel: multiline sample not yet complete", M.readJsonObjects('[\n{\n"engines": {}}'.slice(0, -1)).objects.length, 0)
eq("intel: malformed sample skipped, next sample survives", M.readJsonObjects('{"busy":nan},' + JSON.stringify(intelSample)).objects.length, 1)
eq("intel: unterminated data bounded", M.readJsonObjects('{"bad":"' + "x".repeat(1048576)).remainder, "")
eq("intel: missing-tool message parsed", M.readJsonObjects('{"error":"Install intel-gpu-tools"}\n').objects[0].error, "Install intel-gpu-tools")

// Run the actual QML sampler methods with their properties supplied by a VM.
// A hybrid machine must keep its discrete and integrated histories separate.
const statsSource = readFileSync(new URL("../Stats.qml", import.meta.url), "utf8")
const stats = {
  Model: M, gpu: null, gpuHistory: [], gpuWattsHistory: [], igpuDetected: false,
  igpuPercent: NaN, igpuHistory: [], igpuWatts: NaN, igpuWattsHistory: [],
  packageWatts: NaN, packageWattsHistory: [],
  igpuError: "", igpuBuffer: "", historyLength: 2
}
const gpuMethods = ["applyGpuLine", "applyIgpuLine"].map(name => {
  const method = statsSource.match(new RegExp("  function " + name + "\\([^]*?\\n  \\}"))
  if (!method) throw new Error("Missing sampler method: " + name)
  return method[0]
}).join("\n")
runInNewContext(gpuMethods, stats)
stats.applyGpuLine("NVIDIA GPU, 80, 45, 512, 8188, 23, 210, 30")
stats.applyIgpuLine('{"detected":true}')
for (const busy of [10, 25, 40]) {
  const sample = { engines: { Video: { busy } }, power: { GPU: busy / 10, Package: busy } }
  for (const line of JSON.stringify(sample, null, 2).split("\n")) stats.applyIgpuLine(line)
}
eq("sampler: iGPU detected", stats.igpuDetected, true)
eq("sampler: iGPU current load", stats.igpuPercent, 40)
eq("sampler: bounded iGPU history", stats.igpuHistory.join(","), "25,40")
eq("sampler: discrete GPU load preserved", stats.gpu.utilization, 80)
eq("sampler: discrete GPU history preserved", stats.gpuHistory.join(","), "80")
eq("sampler: discrete GPU watts", stats.gpuWattsHistory.join(","), "23")
eq("sampler: iGPU watts", stats.igpuWatts, 4)
eq("sampler: bounded iGPU watt history", stats.igpuWattsHistory.join(","), "2.5,4")
eq("sampler: package watts", stats.packageWatts, 40)
eq("sampler: bounded package watt history", stats.packageWattsHistory.join(","), "25,40")
stats.applyIgpuLine('{"engines":{}}')
eq("sampler: missing reading does not append zero", stats.igpuHistory.join(","), "25,40")
eq("sampler: missing reading does not append zero watts", stats.packageWattsHistory.join(","), "25,40")

// A machine whose firmware reports no power at all keeps its load history
// and leaves the watt rows empty, rather than drawing a flat zero.
for (const line of JSON.stringify({ engines: { Video: { busy: 50 } } }, null, 2).split("\n")) stats.applyIgpuLine(line)
eq("sampler: load survives without power", stats.igpuPercent, 50)
check("sampler: no power reported, no watts", !isFinite(stats.packageWatts) && !isFinite(stats.igpuWatts))
eq("sampler: no watts appended", stats.packageWattsHistory.join(","), "25,40")
stats.applyIgpuLine('{"error":"Install intel-gpu-tools"}')
eq("sampler: actionable helper error", stats.igpuError, "Install intel-gpu-tools")

// ---- df / ps
const df = M.parseDf(`Filesystem     Mounted on     1B-blocks         Used        Avail Use%
/dev/sdb1      /home         500000000    250000000    250000000  50%
/dev/sda2      /var/log     1000000000    900000000    100000000  90%
/dev/sda2      /            1000000000    900000000    100000000  90%
/dev/sda2      /var/cache/pacman/pkg 1000000000 900000000 100000000  90%`)
eq("df: root first", df[0].mount, "/")
eq("df: percent", df[0].percent, 90)
eq("df: subvolumes collapse per device", df.length, 2)
eq("df: device kept", df[0].device, "/dev/sda2")
const dfNoRoot = M.parseDf(`Filesystem Mounted on 1B-blocks Used Avail Use%
/dev/sdc1 /mnt/data/sub 100 50 50 50%
/dev/sdc1 /mnt/data 100 50 50 50%`)
eq("df: shallowest mount wins", dfNoRoot[0].mount, "/mnt/data")
eq("df: spaces in mount survive", M.parseDf(`Filesystem Mounted on 1B-blocks Used Avail Use%
/dev/sdd1 /mnt/my disk 100 50 50 50%`)[0].mount, "/mnt/my disk")

const procs = M.parseProcesses(` 1234  5.0  2.0 firefox
  222 90.5  1.0 gcc
  333  0.1  0.5 systemd`, 2)
eq("ps: sorted by cpu", procs[0].name, "gcc")
eq("ps: limit honored", procs.length, 2)

// ---- history / formatting
let history = []
for (let i = 0; i < 5; i++) history = M.pushHistory(history, i, 3)
eq("history: capped", history.join(","), "2,3,4")
check("history: new reference each push", M.pushHistory(history, 9, 3) !== history)
eq("history: max with floor", M.historyMax([1, 2, 3], 10), 10)

eq("format: bytes B", M.formatBytes(512), "512B")
eq("format: bytes K", M.formatBytes(2048), "2.0K")
eq("format: bytes G", M.formatBytes(16 * 1024 ** 3), "16G")
eq("format: rate", M.formatRate(1536), "1.5K/s")
eq("format: long bytes", M.formatBytesLong(16 * 1024 ** 3), "16 GB")
eq("format: temperature", M.formatTemperature(54.6), "55°")
eq("format: NaN temperature", M.formatTemperature(NaN), "—")
eq("format: GHz", M.formatMhz(3800), "3.80 GHz")
eq("format: MHz", M.formatMhz(800), "800 MHz")
eq("format: uptime days", M.formatUptime(90000), "1d 1h")
eq("format: uptime minutes", M.formatUptime(300), "5m")

// ---- levels / metric config
eq("level: normal", M.loadLevel(50), "normal")
eq("level: warn", M.loadLevel(80), "warn")
eq("level: critical", M.loadLevel(95), "critical")
eq("level: temperature", M.temperatureLevel(90), "critical")
eq("level: disk warn later", M.diskLevel(80), "normal")

eq("metrics: unknown keys dropped", M.normalizeMetrics(["cpu", "bogus", "mem"]).join(","), "cpu,mem")
eq("metrics: string form", M.normalizeMetrics("cpu, net").join(","), "cpu,net")
eq("metrics: empty falls back", M.normalizeMetrics([]).join(","), "cpu,mem,net")
eq("metrics: duplicates dropped", M.normalizeMetrics(["cpu", "cpu"]).join(","), "cpu")

// ---- bar label
const snapshot = {
  cpu: 42,
  cpuTemperature: 91,
  memory: { percent: 61, swapTotal: 0, swapPercent: 0 },
  gpu: { utilization: 7, temperature: 52 },
  netRx: 1536,
  netTx: 512,
  diskRead: 0,
  diskWrite: 2048
}
const segments = M.barSegments(["cpu", "cpuTemp", "mem", "swap", "gpu", "net"], snapshot)
eq("bar: swap dropped when disabled", segments.map(s => s.key).join(","), "cpu,cpuTemp,mem,gpu,net")
eq("bar: cpu text", segments[0].text, "42%")
eq("bar: hot cpu is critical", segments[1].level, "critical")
eq("bar: icon prefixes the label", segments[0].label, M.METRIC_ICONS.cpu + " 42%")
eq("bar: icons can be dropped", M.barSegments(["cpu"], snapshot, false)[0].label, "42%")
eq("bar: net arrows", segments[4].text, "\u21931.5K \u2191512B")
eq("bar: gpu absent means no segment", M.barSegments(["gpu"], { gpu: null }).length, 0)
eq("bar: gpu watts", M.barSegments(["gpuWatt"], { gpu: { power: 123.4 } })[0].text, "123 W")
eq("bar: a gpu that does not report watts gets no segment", M.barSegments(["gpuWatt"], { gpu: { power: NaN } }).length, 0)
check("bar: gpu watts ask for the helper", M.metricNeedsGpu(["gpuWatt"]))
eq("bar: order follows config", M.barSegments(["net", "cpu"], snapshot).map(s => s.key).join(","), "net,cpu")
check("bar: gpu metrics ask for the helper", M.metricNeedsGpu(["cpu", "gpuTemp"]))
check("bar: no gpu metric, no helper", !M.metricNeedsGpu(["cpu", "mem", "net"]))

// ---- live /proc on this machine
const liveStat = M.parseProcStat(readFileSync("/proc/stat", "utf8"))
check("live: /proc/stat has a total", liveStat.total !== null)
check("live: /proc/stat has cores", liveStat.cores.length > 0)
const liveMem = M.parseMeminfo(readFileSync("/proc/meminfo", "utf8"))
check("live: memory total > 0", liveMem.total > 0)
check("live: memory percent in range", liveMem.percent > 0 && liveMem.percent < 100, String(liveMem.percent))
const liveNet = M.parseNetDev(readFileSync("/proc/net/dev", "utf8"))
check("live: net interfaces found", Object.keys(liveNet.interfaces).length > 0)
check("live: cpu MHz found", M.parseCpuMhz(readFileSync("/proc/cpuinfo", "utf8")).length === liveStat.cores.length)
check("live: uptime > 0", M.parseUptimeSeconds(readFileSync("/proc/uptime", "utf8")) > 0)
check("live: diskstats found a disk", Object.keys(M.parseDiskstats(readFileSync("/proc/diskstats", "utf8"))).length > 0)

if (failures) {
  console.error(`\n${failures} test(s) failed`)
  process.exit(1)
}
console.log("all model tests passed")
