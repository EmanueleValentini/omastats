import QtQuick

// The shell mounts one of these per enabled service plugin, at startup, for
// the whole session. Making the sampler the service means a bar on every
// monitor shares one set of readings instead of each widget instance
// opening its own /proc files.
//
// The bar widget falls back to its own Stats instance when this is not
// loaded, so the plugin still works if only the widget is enabled.
Stats {
  // Injected by the shell's service loader; unused here, but declared so
  // the assignments land somewhere rather than being dropped.
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  property string omarchyPath: ""
}
