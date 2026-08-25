import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "kairos.day-in-history"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: true

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  // The bar label and tooltip are deliberately fixed, author-written strings,
  // never anything fetched from Wikipedia. omarchy-shell renders both through
  // its own AutoText Text elements (Ui/WidgetButton.qml:75, plugins/bar/Bar.qml),
  // which this plugin cannot set textFormat on -- so the fact text is confined
  // to Panel.qml's own PlainText-pinned Text elements instead of ever crossing
  // into a sink this plugin doesn't own. Verified against the installed shell:
  //
  //   grep -rn textFormat /usr/share/omarchy/shell/
  //
  // returns exactly one line -- a StyledText notification body. Every other
  // string the shell renders on a plugin's behalf, this widget's label and
  // tooltip included, is Qt's default AutoText.
  //
  // barSafe() is nonetheless applied to both exported values, wholesale rather
  // than to the fields feeding them. Neither needs it today; the point is that
  // a label which starts carrying fetched text later is covered without anyone
  // having to remember to come back here.
  //
  // The icon is a Nerd Font glyph (nf-fa-bookmark, U+F02E) rather than the
  // Unicode "🔖" emoji: a color-emoji font renders that codepoint in fixed
  // colors regardless of theme, while a Nerd Font glyph is plain outline
  // artwork that inherits the bar's foreground color like every other icon
  // in it (same convention every other installed widget here uses).
  function barSafe(value) {
    var input = String(value === undefined || value === null ? "" : value)
    var out = ""
    for (var i = 0; i < input.length && out.length < 200; i++) {
      var code = input.charCodeAt(i)
      var ch = input.charAt(i)
      if (code < 32 || code === 127) { out += " "; continue }
      if (ch === "<" || ch === ">" || ch === "&") { out += " "; continue }
      out += ch
    }
    return out.trim()
  }

  WidgetButton {
    id: button
    bar: root.bar
    text: root.barSafe("")
    tooltipText: root.barSafe("This Day in History — click for today's fact")
    hasVisualContent: true
    labelVisible: true

    onPressed: root.togglePanel()
  }
}
