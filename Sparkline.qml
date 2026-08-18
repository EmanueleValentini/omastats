import QtQuick
import qs.Commons

// A history strip: one filled line per series, oldest sample on the left.
//
// The y scale is fixed for percentages (0-100) and auto for rates, where
// there is no ceiling to scale against — `maxValue: 0` picks the tallest
// sample in the window, with `minimumScale` keeping an idle network from
// rendering its own noise floor as a mountain range.
Canvas {
  id: root

  property var values: []
  property var secondaryValues: []
  property color stroke: Color.foreground
  property color secondaryStroke: Color.foreground
  property real fillOpacity: 0.14
  property real lineWidth: Style.spacing.hairline * 1.5
  property real maxValue: 100
  property real minimumScale: 1
  // Samples the strip is drawn to hold. A shorter history is drawn at the
  // right-hand edge and grows leftwards, so a fresh panel fills in over
  // time rather than stretching three samples across the whole width.
  property int capacity: 90

  readonly property real scale: {
    if (maxValue > 0) return maxValue
    var peak = Math.max(minimumScale, historyPeak(values), historyPeak(secondaryValues))
    return peak
  }

  function historyPeak(series) {
    var peak = 0
    for (var i = 0; i < (series || []).length; i++) {
      if (series[i] > peak) peak = series[i]
    }
    return peak
  }

  onValuesChanged: requestPaint()
  onSecondaryValuesChanged: requestPaint()
  onStrokeChanged: requestPaint()
  onSecondaryStrokeChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  function drawSeries(ctx, series, color) {
    if (!series || series.length < 2) return

    var slots = Math.max(2, root.capacity)
    var step = root.width / (slots - 1)
    // Right-aligned: the newest sample always sits on the right edge.
    var offset = root.width - (series.length - 1) * step

    ctx.beginPath()
    for (var i = 0; i < series.length; i++) {
      var x = offset + i * step
      var normalized = Math.max(0, Math.min(1, series[i] / root.scale))
      var y = root.height - normalized * (root.height - root.lineWidth) - root.lineWidth / 2
      if (i === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    }

    ctx.strokeStyle = color
    ctx.lineWidth = root.lineWidth
    ctx.lineJoin = "round"
    ctx.stroke()

    // Close the path down to the baseline for the fill, so the line reads as
    // a level rather than as a squiggle.
    ctx.lineTo(offset + (series.length - 1) * step, root.height)
    ctx.lineTo(offset, root.height)
    ctx.closePath()
    ctx.fillStyle = Qt.rgba(color.r, color.g, color.b, root.fillOpacity)
    ctx.fill()
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.clearRect(0, 0, width, height)
    drawSeries(ctx, root.secondaryValues, root.secondaryStroke)
    drawSeries(ctx, root.values, root.stroke)
  }
}
