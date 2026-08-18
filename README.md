# Omastats

Live system statistics for the [Omarchy](https://omarchy.org) bar: a short
row of numbers in the bar, and the full read-out one click away.

The bar shows whichever metrics you pick — CPU, memory and network by
default. Clicking opens a panel with everything the plugin can measure:
per-core load, clock and temperature, memory and swap, GPU load, VRAM and
temperature, every hwmon sensor on the machine, filesystem usage and disk
throughput, per-interface network rates, and the eight processes using the
most CPU. CPU, memory, GPU and network each carry a rolling history strip of
the last ~90 samples.

## Requirements

- Omarchy 4.x (`omarchy-shell`)
- `df` and `ps` (coreutils / procps, already present on any Omarchy install)
- Optional: `nvidia-smi` for NVIDIA GPUs. AMD cards are read from
  `/sys/class/drm/*/device` instead. Machines with neither simply have no
  graphics section.

## Install

```bash
omarchy plugin add https://github.com/EmanueleValentini/omastats --enable
```

Or manually:

```bash
git clone https://github.com/EmanueleValentini/omastats \
  ~/.config/omarchy/plugins/io.github.emanuelevalentini.omastats
omarchy plugin enable io.github.emanuelevalentini.omastats right
omarchy-restart-shell
```

The second argument to `enable` is the bar section (`left`, `center`,
`right`).

## Usage

| Action | Result |
|---|---|
| Left click | Open / close the full panel |
| Right click | Cycle the bar through the metric presets |
| Middle click | Open `btop` in a terminal |
| `↑` / `↓` in the panel | Scroll |
| `Esc` | Close the panel |

From a script or a keybinding:

```bash
omarchy-shell omastats toggle          # open/close the panel
omarchy-shell omastats open
omarchy-shell omastats close
omarchy-shell omastats cycleMetrics    # next metric preset
```

## Configuration

Settings live in the widget's own entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "io.github.emanuelevalentini.omastats",
  "metrics": ["cpu", "cpuTemp", "mem", "net"],
  "interval": 1000,
  "showIcons": true
}
```

| Key | Default | Meaning |
|---|---|---|
| `metrics` | `["cpu", "mem", "net"]` | Which readings the bar shows, in order |
| `interval` | `1000` | Sampling interval in milliseconds (minimum 250) |
| `showIcons` | `true` | Show the glyph in front of each bar reading |

Available `metrics` values: `cpu`, `cpuTemp`, `mem`, `swap`, `gpu`,
`gpuTemp`, `net`, `disk`. Metrics with nothing to report are dropped rather
than shown empty — `swap` on a machine with swap off, `gpu` where no GPU can
be read. Right-clicking the widget cycles the presets and writes the result
back to this entry, so the bar you end up with is the bar you get after a
restart.

## How it samples

Readings come from `/proc` and `/sys` directly, inside the shell process —
no subprocess per tick. Three things cannot be read that way and get a
helper:

- `bin/omastats-sensors` runs once at startup to find the machine's hwmon
  temperature files, because QML cannot list a directory.
- `bin/omastats-gpu` streams GPU samples, and runs only while a GPU reading
  is actually on screen.
- `df` and `ps` run only while the panel is open.

The sampler is a `service` plugin, so a bar on each monitor shares one set of
readings rather than each widget instance opening its own files. Closing the
panel stops everything except the ~1 kB/s of `/proc` reads behind the bar
label.

## Development

```bash
node tests/model.test.mjs   # parsers and formatters, against fixtures and live /proc
./dev-install.sh            # copy into the plugin dir, validate, restart the shell
./dev-install.sh --no-restart
```

Omarchy refuses to load a plugin folder containing symlinks, so the working
tree is copied into `~/.config/omarchy/plugins/` rather than linked.

All parsing and formatting lives in `Model.js` as side-effect-free functions
that run both in the QML engine and under node, which is what makes the test
suite possible without a running compositor.

## Uninstall

```bash
omarchy plugin remove io.github.emanuelevalentini.omastats
```

## License

MIT — see [LICENSE](LICENSE).
