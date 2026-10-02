// Jump to Window — workspace-category switcher + window jump panel.
//
// Two independent surfaces live in this one plugin:
//
//   1. `chip`  — a transient "6 · messaging" label on every workspace change.
//                Its own layer-shell surface with no input region, so it shows
//                regardless of the notification service (and so regardless of
//                DND). That is why this is not omarchy-notification-send.
//   2. `panel` — the summoned jump panel, listing workspaces and their
//                windows. Summoned via SUPER+SHIFT+J.
//
// Kept in one file deliberately: both surfaces read the same Hyprland window
// and workspace state, and splitting them would load that state twice for one
// keystroke.

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  // Injected by omarchy-shell when present; defaults keep it loadable alone.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var manifest: null
  property var shell: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0

  // Flat focusable list. A row is either a workspace header (switch
  // workspace) or a window (focus window). Flattening headers into the same
  // cursor is what lets one panel serve both "switch category" and "jump to
  // window" with no mode switch.
  property var rows: []

  readonly property int currentWorkspaceId: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0

  Component.onCompleted: console.log("local.jump: root constructed")

  // NOTE: this plugin sets `keepLoaded: true` in manifest.json because the
  // chip must stay mounted to observe Hyprland.workspace changes. The shell
  // README is explicit that "the kept instance is not replaced, so code
  // changes to a keepLoaded service itself only take effect on a shell
  // restart" -- and empirically a hot reload builds a second root without
  // destroying the first (onDestruction never fires, so both chips then
  // draw on the same workspace and the stale one wins). So: edit, then run
  // `omarchy-restart-shell`. Do not trust a hot reload to show the change.

  // ------------------------------------------------------------------ chip

  property bool chipVisible: false
  property int chipWorkspaceId: 0

  function showChip(id) {
    if (id <= 0) return
    chipWorkspaceId = id
    chipVisible = true
    chipTimer.restart()
  }

  onCurrentWorkspaceIdChanged: showChip(root.currentWorkspaceId)

  // ------------------------------------------------------------- data model

  function workspaceNameFor(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) {
        var n = values[i].name
        // Hyprland names an unnamed workspace with its own number as a
        // string; surfacing that as a category label is noise.
        return (n === undefined || n === null || n === "" || n === String(id)) ? "" : n
      }
    }
    return ""
  }

  // Quickshell reports a toplevel address without the 0x prefix while the
  // Hyprland dispatcher requires it. Normalise once here so no caller has to
  // know which form it is holding.
  function addressOf(toplevel) {
    var a = String(toplevel.address === undefined ? "" : toplevel.address)
    if (a === "") return ""
    return a.indexOf("0x") === 0 ? a : "0x" + a
  }

  // The WM class does not live on Quickshell's HyprlandToplevel: the type has
  // no `class` property, and its `name` is declared but never populated, so
  // both read as undefined. The class is on the Wayland toplevel that the
  // Hyprland one wraps, exposed as `appId` -- the same source Omarchy's own
  // ActiveWindow bar widget reads. This is what lets "chrome" match a browser
  // row no matter what the page is called.
  //
  // `byTitle` is a title -> class index built once per rebuild. It is only a
  // fallback for the window whose `wayland` link has not resolved yet, which
  // happens for a toplevel in the moments right after it maps.
  function classOf(toplevel, byTitle) {
    var w = toplevel.wayland
    if (w && w.appId !== undefined && w.appId !== null && String(w.appId) !== "") {
      return String(w.appId)
    }
    if (byTitle) {
      var key = String(toplevel.title)
      if (key !== "" && byTitle[key] !== undefined) return byTitle[key]
    }
    return "window"
  }

  // An untitled window is normal (fresh terminals, launchers, some games).
  // Falling back to the class keeps those rows identifiable instead of
  // rendering as a blank line.
  function titleFor(toplevel, byTitle) {
    var t = String(toplevel.title === undefined ? "" : toplevel.title).trim()
    if (t !== "") return t
    return root.classOf(toplevel, byTitle)
  }

  function classIndex() {
    var map = {}
    var values = ToplevelManager.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var k = String(values[i].title)
      var v = String(values[i].appId)
      if (k !== "" && v !== "" && map[k] === undefined) map[k] = v
    }
    return map
  }

  function matchesFilter(row, needle) {
    if (needle === "") return true
    // A workspace row matches on its category name; a window row matches on
    // its title or its class, so "chrome" finds every browser regardless of
    // what the page is called. The window field is `cls`, not `class` --
    // `class` is a reserved-ish word in QML and is not what rebuild() stores.
    var hay = row.type === "workspace"
      ? row.name + " " + row.id
      : row.title + " " + row.cls
    return hay.toLowerCase().indexOf(needle) !== -1
  }

  function rebuild() {
    var needle = root.filterText.trim().toLowerCase()
    var next = []
    var toplevels = Hyprland.toplevels.values
    var byTitle = root.classIndex()

    // Only 1-10 are first-class categories here. Special workspaces
    // (scratch, magic) and anything above the taxonomy stay reachable by
    // keybind but unlisted, which holds the panel to the agreed ten.
    for (var id = 1; id <= 10; id++) {
      // A header carries the same fields a window row does, defaulted to
      // empty. Both halves of the delegate are instantiated for every row
      // (only one is visible), so without these the header half reads
      // `title`/`cls`/`focused` off a row that has no such keys and QML warns
      // "Unable to assign [undefined]" once per row per field.
      var header = {
        type: "workspace",
        id: id,
        name: root.workspaceNameFor(id),
        windowCount: 0,
        title: "",
        cls: "",
        address: "",
        focused: false
      }
      var windows = []

      for (var i = 0; i < toplevels.length; i++) {
        var t = toplevels[i]
        var ws = t.workspace ? t.workspace.id : -1
        if (ws !== id) continue

        var addr = root.addressOf(t)
        // No address means not yet mapped, so it cannot be focused. Listing
        // it would offer a row that silently does nothing on Enter.
        if (addr === "") continue

        windows.push({
          type: "window",
          id: id,
          address: addr,
          // name is blank on a window row: it is the workspace header's field.
          // Both halves of the delegate are built for every row, so every row
          // must carry every key the delegate reads.
          name: "",
          cls: root.classOf(t, byTitle),
          title: root.titleFor(t, byTitle),
          focused: t.focused === true
        })
      }

      windows.sort(function(a, b) {
        var l = a.title.toLowerCase(), r = b.title.toLowerCase()
        return l < r ? -1 : (l > r ? 1 : 0)
      })

      header.windowCount = windows.length

      // A workspace with no windows still gets a header: it is a category the
      // user may want to switch to, and dropping empties would make several
      // of the ten simply not exist in the panel.
      if (root.matchesFilter(header, needle)) next.push(header)
      for (var w = 0; w < windows.length; w++) {
        if (root.matchesFilter(windows[w], needle)) next.push(windows[w])
      }
    }

    root.rows = next
    root.selectedIndex = Util.clamp(root.selectedIndex, 0, Math.max(0, next.length - 1))
  }

  // Row heights are needed in two places (the Column and the scroll maths),
  // so they are defined once here rather than repeated as literals.
  readonly property int headerRowHeight: Style.space(38)
  readonly property int windowRowHeight: Style.space(30)

  function rowY(index) {
    var y = 0
    for (var i = 0; i < index; i++) {
      y += root.rows[i].type === "workspace" ? root.headerRowHeight : root.windowRowHeight
    }
    return y
  }

  // -------------------------------------------------------------- lifecycle

  // The summon payload is optional. `summon local.jump` and
  // `summon local.jump '{}'` both reach here with no filter; a caller can
  // pre-seed one with `summon local.jump '{"filter":"chrome"}'`. Malformed
  // JSON is treated as "no payload" rather than an error, because a typo in a
  // keybind should still open the panel.
  function open(payloadJson) {
    var seed = ""
    if (payloadJson) {
      try {
        var payload = JSON.parse(String(payloadJson))
        if (payload && typeof payload.filter === "string") seed = payload.filter
      } catch (e) {
        seed = ""
      }
    }

    root.filterText = seed
    root.selectedIndex = 0
    root.rebuild()
    root.opened = true
    // Focus must be requested after the window maps, or the layer-shell
    // surface is not yet ready to take it. The field, not the catcher:
    // the catcher is `blocked` while the field has focus, so focus has to
    // land on the field for typing to work at all.
    Qt.callLater(function() { filterField.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.filterText = ""
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function moveCursor(delta) {
    if (root.rows.length === 0) return
    root.selectedIndex = Util.clamp(root.selectedIndex + delta, 0, root.rows.length - 1)
    list.ensureVisible(root.selectedIndex)
  }

  // Clicking moves the cursor but does not commit. A click that both selects
  // and activates would focus whatever row the cursor happened to be on,
  // which is not always the row under the pointer.
  function selectFromPointer(index) {
    root.selectedIndex = index
  }

  function activateIndex(index) {
    if (index < 0 || index >= root.rows.length) return
    var row = root.rows[index]

    if (row.type === "workspace") {
      Util.execDetached("hyprctl dispatch 'hl.dsp.focus({ workspace = \"" + row.id + "\" })'")
    } else {
      Util.execDetached("hyprctl dispatch 'hl.dsp.focus({ window = \"address:" + row.address + "\" })'")
    }
    root.close()
  }

  function refreshIfOpen() {
    if (root.opened) root.rebuild()
  }

  // ------------------------------------------------------------------- IPC

  IpcHandler {
    target: "jump"
    function open(payloadJson: string): string { root.open(payloadJson); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function state(): string { return root.opened ? "open" : "closed" }
    function ping(): string { return "ok" }
  }

  // -------------------------------------------------------------- chrome

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color scrimColor: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accentColor: Color.accent
  readonly property int cornerRadius: Style.cornerRadius

  // ---------------------------------------------------------- chip appearance
  //
  // Four knobs, deliberately. The defaults are the borderless look: no
  // plate, no border, display-sized type floating straight over whatever
  // is on screen.
  //
  //   chipFontSize  - logical px. Defaults to Style.font.display, which is
  //                   ~1.7x title and still tracks the user's font scale,
  //                   so the chip grows when the whole shell does.
  //   chipOpacity   - alpha of the plate behind the text. 0 = no plate at all;
  //                   0..1 tints the menu background to that alpha.
  //   chipShadow    - drop shadow behind the text. Leave this on while
  //                   chipOpacity is low: bare foreground-coloured text over
  //                   an arbitrary window is not reliably readable.
  //   chipTopMargin - distance from the top of the screen, logical px.
  //
  // The plate and its border are separate knobs so the border can carry the
  // accent while the plate stays neutral -- a coloured outline reads as
  // deliberate, a coloured fill at 50% just looks muddy. The border is off
  // by default; raise chipBorderWidth to bring it back.
  property int    chipFontSize:  Style.font.display
  property real   chipOpacity:   0.5
  property bool   chipShadow:    true
  property real   chipTopMargin: 48

  // Fixed width, so the chip does not resize as the workspace name changes
  // length -- it holds still instead of twitching on every switch. Sized at
  // roughly twice the text-driven width. Scaled by Style.space() so it
  // still tracks DPI. Set to 0 to go back to hugging the content.
  property int    chipWidth:     Style.space(340)
  property color  chipBorderColor: root.accentColor
  property int    chipBorderWidth: 0

  // Corner rounding. Defaults to the shell's control radius; set it to
  // chipHeight / 2 for a full pill.
  property real   chipRadius:    root.cornerRadius

  // Height tracks the type instead of being a fixed plate, so a larger
  // chipFontSize cannot clip descenders.
  readonly property int chipHeight: root.chipFontSize + Style.space(14)

  // ---------------------------------------------------------------- chip surface

  Timer {
    id: chipTimer
    interval: 1400
    onTriggered: root.chipVisible = false
  }

  PanelWindow {
    id: chipWindow
    visible: root.chipVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "local-jump-chip"
    WlrLayershell.layer: WlrLayer.Top
    // No input region: the chip must never intercept a click meant for the
    // window underneath it.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    Rectangle {
      id: chip
      // chipWidth 0 falls back to hugging the content.
      width: root.chipWidth > 0 ? root.chipWidth : chipRow.implicitWidth + Style.space(28)
      height: root.chipHeight
      radius: root.chipRadius
      // chipOpacity 0 = no plate at all. Above that it tints the menu
      // background, so the chip stays neutral while the border carries
      // the colour.
      color: root.chipOpacity > 0
        ? Qt.rgba(root.background.r, root.background.g, root.background.b, root.chipOpacity)
        : "transparent"
      border.width: root.chipBorderWidth
      border.color: root.chipBorderColor
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: root.chipTopMargin

      Row {
        id: chipRow
        anchors.centerIn: parent
        spacing: Style.space(8)

        // Contrast for the borderless case. Without a plate behind it the
        // text draws straight onto the window below, and a light chip over
        // a light window disappears.
        layer.enabled: root.chipShadow
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowBlur: 1.0
          shadowScale: 1.0
          shadowColor: Qt.rgba(0, 0, 0, 0.55)
          shadowHorizontalOffset: 0
          // Offset tracks the type size so a bigger chip does not get a
          // shadow that reads as a separate smudge underneath it.
          shadowVerticalOffset: Math.max(1, Math.round(root.chipFontSize / 8))
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: String(root.chipWorkspaceId)
          color: root.selectedText
          font.family: Style.font.family
          font.pixelSize: root.chipFontSize
          font.bold: true
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: text !== ""
          text: "·"
          color: root.foreground
          opacity: 0.5
          font.family: Style.font.family
          font.pixelSize: root.chipFontSize
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: text !== ""
          text: root.workspaceNameFor(root.chipWorkspaceId)
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: root.chipFontSize
        }
      }
    }
  }

  // ----------------------------------------------------------------- panel surface

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "local-jump-panel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrimColor

      // Swallow scrim clicks so they dismiss the panel instead of reaching
      // the window below it.
      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }

      BorderSurface {
        id: card
        width: Math.min(Style.space(620), panel.width - Style.gapsOut * 2)
        height: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)
        anchors.centerIn: parent

        Rectangle {
          anchors.fill: parent
          color: root.background
          radius: root.cornerRadius
          // Literal 1, not Style.space(2): space() scales with DPI, so a
          // scaled value rendered 2px+ here. A hairline is a hairline.
          border.width: 1
          border.color: root.borderColor
        }

        ColumnLayout {
          anchors.fill: parent
          anchors.leftMargin: card.contentLeftInset + Style.space(10)
          anchors.rightMargin: card.contentRightInset + Style.space(10)
          anchors.topMargin: card.contentTopInset + Style.space(10)
          anchors.bottomMargin: card.contentBottomInset + Style.space(6)
          spacing: Style.spacing.sm

          // Header -------------------------------------------------------
          RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(8)
            Layout.rightMargin: Style.space(8)
            spacing: Style.spacing.md

            Text {
              text: "Jump to window"
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Item { Layout.fillWidth: true }

            // The filter is a real TextField, not a string built from
            // keyCatcher.textKey. PanelKeyCatcher has no Qt.Key_Backspace
            // case, so backspace arrives through its generic `text.length
            // === 1` branch as U+0008 -- appending that rendered one tofu
            // box per press. A real field also gives Delete, Ctrl+W, Home/
            // End and selection for free. Nav keys are re-forwarded below so
            // typing does not cost the arrow keys.
            TextField {
              id: filterField
              Layout.preferredWidth: Style.space(240)
              Layout.maximumWidth: Style.space(240)
              verticalPadding: Style.space(2)
              text: root.filterText
              placeholderText: "filter…"
              foreground: root.foreground
              accent: root.accentColor
              font.family: Style.font.family
              font.pixelSize: Style.font.body

              // onTextEdited (not onTextChanged) so that programmatic seeding
              // from the summon payload updates the field without also firing
              // the handler -- and without the `text: root.filterText` binding
              // being torn down by an assignment to the bound property.
              onTextEdited: {
                root.filterText = text
                root.selectedIndex = 0
                root.rebuild()
              }

              // PanelKeyCatcher runs at Keys.BeforeItem, so it sees these
              // before the field does. Taking them here keeps arrow/Return
              // navigation working while the field owns text editing.
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.close(); event.accepted = true; return
                }
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.activateIndex(root.selectedIndex); event.accepted = true; return
                }
                if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  root.moveCursor(event.key === Qt.Key_Backtab ? -1 : 1); event.accepted = true; return
                }
                if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                  root.moveCursor(event.key === Qt.Key_Down ? 1 : -1); event.accepted = true; return
                }
                if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
                  root.moveCursor(event.key === Qt.Key_PageDown ? 8 : -8); event.accepted = true; return
                }
              }
            }
          }

          PanelSeparator {}

          // Rows ---------------------------------------------------------
          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Flickable {
              id: list
              anchors.fill: parent
              clip: true
              contentWidth: width
              contentHeight: column.implicitHeight
              boundsBehavior: Flickable.StopAtBounds

              // Keep the keyboard cursor on screen. Heights come from the same
              // root properties the delegates use, so the scroll maths and
              // the rendered rows cannot drift apart.
              function ensureVisible(index) {
                if (index < 0 || index >= root.rows.length) return
                var rowH = root.rows[index].type === "workspace" ? root.headerRowHeight : root.windowRowHeight
                var top = root.rowY(index)
                if (top < contentY) contentY = top
                else if (top + rowH > contentY + height) contentY = top + rowH - height
              }

              Column {
                id: column
                width: list.width

                Repeater {
                  model: root.rows

                  delegate: Item {
                    id: rowItem
                    required property int index
                    required property var modelData

                    readonly property bool isWorkspace: modelData.type === "workspace"
                    readonly property bool selected: index === root.selectedIndex

                    width: column.width
                    height: rowItem.isWorkspace ? root.headerRowHeight : root.windowRowHeight

                    Rectangle {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(4)
                      anchors.rightMargin: Style.space(4)
                      radius: Style.cornerRadius
                      color: rowItem.selected ? root.selectedBackground : "transparent"
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onPositionChanged: root.selectFromPointer(rowItem.index)
                      onClicked: root.activateIndex(rowItem.index)
                    }

                    // Workspace header: "6  messaging   5 windows"
                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(14)
                      anchors.rightMargin: Style.space(14)
                      spacing: Style.spacing.sm
                      visible: rowItem.isWorkspace

                      Text {
                        text: String(rowItem.modelData.id)
                        color: rowItem.selected ? root.selectedText : root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        Layout.minimumWidth: Style.space(16)
                      }

                      Text {
                        text: rowItem.modelData.name
                        color: rowItem.selected ? root.selectedText : root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                      }

                      Text {
                        // "empty" reads better than "0": it distinguishes a
                        // category not yet used from a broken count.
                        text: rowItem.modelData.windowCount === 0
                          ? "empty"
                          : rowItem.modelData.windowCount + " windows"
                        color: root.foreground
                        opacity: rowItem.modelData.windowCount === 0 ? 0.4 : 0.6
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    // Window row: title + class
                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(34)
                      anchors.rightMargin: Style.space(14)
                      spacing: Style.spacing.sm
                      visible: !rowItem.isWorkspace

                      Text {
                        text: "↳"
                        color: root.foreground
                        opacity: 0.4
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        text: rowItem.modelData.title
                        color: rowItem.selected ? root.selectedText : root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: rowItem.modelData.focused
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                      }

                      Text {
                        text: rowItem.modelData.cls
                        color: root.foreground
                        opacity: 0.45
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                        Layout.maximumWidth: Style.space(170)
                      }
                    }
                  }
                }
              }
            }

            // Empty state -------------------------------------------------
            ColumnLayout {
              anchors.centerIn: parent
              width: parent.width
              visible: root.rows.length === 0

              Text {
                Layout.alignment: Qt.AlignHCenter
                text: root.filterText === ""
                  ? "No windows open"
                  : "No matches for “" + root.filterText + "”"
                color: root.foreground
                opacity: 0.7
                font.family: Style.font.family
                font.pixelSize: Style.font.title
              }
            }
          }

          PanelSeparator {}

          // Footer -------------------------------------------------------
          Text {
            Layout.fillWidth: true
            Layout.bottomMargin: Style.space(4)
            text: "↑↓ move   ⏎ focus   esc dismiss   ⌫ delete"
            color: root.foreground
            opacity: 0.45
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }
        }

        // Key catcher overlays the whole card rather than living in the
        // ColumnLayout above: it has no visual content, so giving it layout
        // space would steal height from the window list. Anchoring it to the
        // card makes it the single key-focusable surface for the entire panel.
        //
        // `blocked` hands text editing to the real TextField in the header.
        // Without it the catcher consumes printable keys as vim motions
        // (h/j/k/l move the cursor) and never reaches the field.
        PanelKeyCatcher {
          id: keyCatcher
          anchors.fill: parent
          blocked: filterField.activeFocus
          onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx) }
          onActivateRequested: root.activateIndex(root.selectedIndex)
          onCloseRequested: root.close()
        }
      }
    }
  }

  // Windows can open or close without the focused window changing (opening a
  // background window, closing one that was not focused). Hyprland exposes no
  // aggregate "toplevels changed" signal to hang a Connections block on -- the
  // focusedWindowChanged handler does not resolve on this Hyprland singleton --
  // so a slow tick while the panel is open is what keeps the rows honest.
  Timer {
    interval: 700
    running: root.opened
    repeat: true
    onTriggered: root.refreshIfOpen()
  }
}
