import QtQuick
import QtTest
import ".."
import "../Layout.js" as Layout

Item {
  id: scene
  width: 2304; height: 900
  property var windows: []
  QtObject { id: first; property size sourceSize: Qt.size(800, 1000); property bool hasContent: false; property bool hasFrame: true; property var image: null }
  QtObject { id: second; property size sourceSize: Qt.size(950, 1000); property bool hasContent: false; property bool hasFrame: true; property var image: null }
  QtObject { id: third; property size sourceSize: Qt.size(1100, 1000); property bool hasContent: false; property bool hasFrame: true; property var image: null }
  // One synthetic native frame with content, shared by the grid card and the strip
  // thumbnail below. A ScreencopyView cannot exist headlessly and nothing in this
  // file may create, retain or release a capture, so the "frame" is a plain Item and
  // no image is ever read from disk.
  Item { id: nativeFrame; x: 2100; y: 1200; width: 1600; height: 1000 }
  QtObject {
    id: shared
    property size sourceSize: Qt.size(1600, 1000)
    property bool hasContent: true
    property bool hasFrame: true
    property bool fresh: true
    property bool allowStart: true
    property var image: nativeFrame
  }
  property var extraCaptures: ({})
  function captureFor(address) {
    return ({ a: first, b: second, c: third })[address] || scene.extraCaptures[address] || null
  }
  readonly property string layoutKey: JSON.stringify(windows.map(w => Layout.aspectFor(w, captureFor(w.address))))
  readonly property var placements: Layout.arrange(JSON.parse(layoutKey), width, height)
  Repeater {
    id: cards
    model: scene.windows
    delegate: WindowPreview {
      required property var modelData
      required property int index
      readonly property var rect: scene.placements[index] || ({ x: 0, y: 0, width: 0, height: 0 })
      x: rect.x; y: rect.y; width: rect.width; height: rect.height
      windowInfo: modelData; sharedCapture: scene.captureFor(modelData.address)
    }
  }
  // A card whose geometry the test drives directly: the grid cards above are bound to
  // the packed cells, and the FBO-churn and title cases need an independent size.
  property var soloWindow: null
  property var soloCapture: null
  WindowPreview {
    id: solo
    objectName: "soloCard"
    x: 60; y: 1200; width: 300; height: 400
    windowInfo: scene.soloWindow
    sharedCapture: scene.soloCapture
  }
  property var stripMembers: []
  property bool stripHovered: false
  property bool stripCanRemove: false
  property bool stripDropTarget: false
  DesktopPreview {
    id: strip
    objectName: "strip"
    x: 700; y: 1200
    desktopId: 3
    members: scene.stripMembers
    captureFor: address => scene.captureFor(address)
    hovered: scene.stripHovered
    canRemove: scene.stripCanRemove
    dropTarget: scene.stripDropTarget
  }
  TestCase {
    name: "OverviewWindowLayout"; when: windowShown
    function init() {
      scene.width = 2304; scene.height = 900
      first.sourceSize = Qt.size(800, 1000)
      second.sourceSize = Qt.size(950, 1000)
      third.sourceSize = Qt.size(1100, 1000)
      scene.windows = ["a", "b", "c"].map(address => ({ address: address, title: "Test window", lastIpcObject: { size: [1600, 1000] } }))
      scene.extraCaptures = ({})
      shared.sourceSize = Qt.size(1600, 1000)
      shared.hasContent = true
      shared.fresh = true
      shared.allowStart = true
      shared.image = nativeFrame
      scene.soloWindow = ({ address: "solo", title: "Solo", lastIpcObject: { class: "org.test.Solo", size: [1600, 1000] } })
      scene.soloCapture = shared
      solo.width = 300; solo.height = 400; solo.showTitle = true
      scene.stripMembers = []
      scene.stripHovered = false
      scene.stripCanRemove = false
      scene.stripDropTarget = false
      wait(0)
    }
    function assertFitted() {
      for (let i = 0; i < cards.count; i++) {
        const surface = cards.itemAt(i).surface
        const point = surface.mapToItem(scene, 0, 0)
        const rect = scene.placements[i]
        fuzzyCompare(point.x, rect.x, .51, "Visible left edge must equal the packed cell")
        fuzzyCompare(point.y, rect.y, .51, "Visible top edge must equal the packed cell")
        fuzzyCompare(surface.width, rect.width, .01, "Visible width must equal the packed cell")
        fuzzyCompare(surface.height, rect.height, .01, "Visible height must equal the packed cell")
      }
    }
    // Weaker than assertFitted and true for every stage: arrange() may pack a cell at
    // its ratio bound (Layout.js bounds packing to [.005, 20]), and the card then
    // letterboxes the true ratio inside that cell instead of filling it.
    function assertContained() {
      for (let i = 0; i < cards.count; i++) {
        const card = cards.itemAt(i)
        const surface = card.surface
        const cell = scene.placements[i] || ({ x: 0, y: 0, width: 0, height: 0 })
        const point = surface.mapToItem(scene, 0, 0)
        verify(surface.width <= cell.width + .01, "Card " + i + " must letterbox inside its cell width")
        verify(surface.height <= cell.height + .01, "Card " + i + " must letterbox inside its cell height")
        verify(surface.width >= 0 && surface.height >= 0, "Card " + i + " must never be inverted")
        // anchors.centerIn rounds each half to whole pixels, so a letterboxed frame can
        // sit up to one pixel off the exact centre of a fractional cell.
        fuzzyCompare(point.x + surface.width / 2, cell.x + cell.width / 2, 1.01, "Card " + i + " must stay centred in its cell")
        fuzzyCompare(point.y + surface.height / 2, cell.y + cell.height / 2, 1.01, "Card " + i + " must stay centred in its cell")
        if (surface.width > 0 && surface.height > 0)
          fuzzyCompare(surface.width / surface.height, card.aspect, card.aspect * .002,
                       "Card " + i + " must keep its native aspect, letterboxed and never distorted")
      }
    }
    function assertInsideStage() {
      for (let i = 0; i < cards.count; i++) {
        const surface = cards.itemAt(i).surface
        const point = surface.mapToItem(scene, 0, 0)
        verify(point.x >= -.51 && point.y >= -.51, "Card " + i + " must not start off-stage")
        verify(point.x + surface.width <= scene.width + .51, "Card " + i + " must not run past the stage width")
        verify(point.y + surface.height <= scene.height + .51, "Card " + i + " must not run past the stage height")
      }
    }
    function assertNoOverlap() {
      const rects = []
      for (let i = 0; i < cards.count; i++) {
        const surface = cards.itemAt(i).surface
        const point = surface.mapToItem(scene, 0, 0)
        if (surface.width > .01 && surface.height > .01)
          rects.push({ x: point.x, y: point.y, w: surface.width, h: surface.height })
      }
      for (let i = 0; i < rects.length; i++)
        for (let j = i + 1; j < rects.length; j++) {
          const a = rects[i], b = rects[j]
          verify(!(a.x < b.x + b.w - .02 && b.x < a.x + a.w - .02 && a.y < b.y + b.h - .02 && b.y < a.y + a.h - .02),
                 "Visible cards " + i + " and " + j + " must not overlap")
        }
    }
    // Either every card sits exactly in its packed cell, or the layout refused the
    // stage and every card collapses to nothing. Layout.js has no third shape.
    function assertRefusedOrFitted() {
      if (scene.placements.length === 0) {
        compare(scene.placements.length, 0)
        for (let i = 0; i < cards.count; i++) {
          const surface = cards.itemAt(i).surface
          compare(surface.width, 0, "A refused layout must not draw a sliver")
          compare(surface.height, 0, "A refused layout must not draw a sliver")
        }
      } else {
        compare(scene.placements.length, cards.count, "arrange() must place every card or none")
        assertFitted()
      }
      assertInsideStage()
      assertNoOverlap()
    }
    function tilesOf(preview) {
      const out = []
      for (let i = 0; i < preview.children.length; i++)
        if (preview.children[i].objectName === "desktopTile") out.push(preview.children[i])
      return out
    }
    function descendants(item) {
      const out = []
      const queue = [item]
      while (queue.length && out.length < 4000) {
        const node = queue.shift()
        out.push(node)
        const kids = node && node.data !== undefined ? node.data : (node ? node.children : null)
        if (kids)
          for (let i = 0; i < kids.length; i++) if (kids[i]) queue.push(kids[i])
      }
      return out
    }
    function test_threeCapturedWindowsUseEqualVisibleGaps() {
      assertFitted()
      const surfaces = [0, 1, 2].map(i => cards.itemAt(i).surface)
      const points = surfaces.map(surface => surface.mapToItem(scene, 0, 0))
      for (let i = 1; i < 3; i++) {
        fuzzyCompare(points[i].y, points[0].y, .51)
        fuzzyCompare(points[i].x - points[i - 1].x - surfaces[i - 1].width, 44, 1)
      }
      fuzzyCompare(points[0].x, scene.width - points[2].x - surfaces[2].width, 1)
    }
    function test_lateCaptureResizeAndMonitorResizeStayFitted() {
      third.sourceSize = Qt.size(0, 0); wait(0); assertFitted()
      third.sourceSize = Qt.size(600, 1000); wait(0); assertFitted()
      second.sourceSize = Qt.size(2200, 1000); wait(0); assertFitted()
      scene.width = 1504; scene.height = 730; wait(0); assertFitted()
      const original = scene.windows
      scene.windows = [original[2], original[0]]; wait(0); assertFitted()
      scene.windows = original; wait(0); assertFitted()
    }
    function test_extremeButValidRatiosDoNotLeaveHoles() {
      first.sourceSize = Qt.size(100, 1000)
      third.sourceSize = Qt.size(8000, 1000)
      wait(0); assertFitted()
    }
    // ---- stage extremes -----------------------------------------------------
    function test_tinyStagesRefuseInsteadOfDrawingSlivers() {
      const tiny = [[1504, 41], [1504, 34], [200, 40], [1, 1], [0, 900], [2304, 0]]
      for (let i = 0; i < tiny.length; i++) {
        scene.width = tiny[i][0]; scene.height = tiny[i][1]; wait(0)
        compare(scene.placements.length, 0, "A stage of " + tiny[i][0] + "x" + tiny[i][1] + " must be refused, not packed")
        assertRefusedOrFitted()
        for (let c = 0; c < cards.count; c++) {
          const card = cards.itemAt(c)
          compare(card.hasThumbnail, false)
          verify(findChild(card, "previewPlaceholder").visible, "A refused card still explains itself")
        }
      }
      // One pixel more of stage and the same three windows pack again, at the floor.
      scene.width = 1504; scene.height = 42; wait(0)
      compare(scene.placements.length, 3)
      fuzzyCompare(scene.placements[0].height, 8, .001, "8 px is the labelled-stage floor")
      assertRefusedOrFitted()
      // The floor is on the shared cell height only: a 12 px wide stage still packs
      // three cards, narrow but visible, inside their stage and without overlapping.
      scene.width = 12; scene.height = 900; wait(0)
      compare(scene.placements.length, 3)
      verify(scene.placements[0].height >= 8)
      verify(scene.placements[0].width <= 12.01)
      assertRefusedOrFitted()
    }
    function test_hugeStagesStayBoundedAndFitted() {
      const huge = [[15360, 8640], [15360, 200], [3840, 12000], [2304, 900]]
      for (let i = 0; i < huge.length; i++) {
        scene.width = huge[i][0]; scene.height = huge[i][1]; wait(0)
        compare(scene.placements.length, 3)
        verify(scene.placements[0].height <= 640.01, "A card is never scaled past the 640 px cap")
        assertRefusedOrFitted()
      }
      scene.width = 15360; scene.height = 8640; wait(0)
      fuzzyCompare(cards.itemAt(0).surface.height, 640, .01)
    }
    function test_zeroCardsAndManyCardsBothStayFitted() {
      scene.windows = []; wait(0)
      compare(cards.count, 0)
      compare(scene.placements.length, 0)
      assertRefusedOrFitted()
      const many = []
      for (let i = 0; i < 40; i++)
        many.push({ address: "w" + i, title: "Window " + i,
                    lastIpcObject: { class: "app" + i, size: [1200 + i * 30, 700 + i * 5] } })
      scene.windows = many; wait(0)
      compare(cards.count, 40)
      compare(scene.placements.length, 40)
      verify(scene.placements[0].height >= 8, "Forty cards must still be visible, not slivers")
      assertRefusedOrFitted()
      assertContained()
      // Forty cards on a 600x120 stage still pack, above the 8 px floor and without
      // overlapping; one step smaller and the whole layout refuses rather than
      // producing forty invisible cards.
      scene.width = 600; scene.height = 120; wait(0)
      compare(scene.placements.length, 40)
      verify(scene.placements[0].height >= 8)
      assertRefusedOrFitted()
      scene.width = 600; scene.height = 80; wait(0)
      compare(scene.placements.length, 0, "Forty cards must refuse this stage, not shrink into it")
      assertRefusedOrFitted()
      scene.width = 2304; scene.height = 900
      scene.windows = many.slice(0, 3); wait(0)
      assertRefusedOrFitted()
    }
    function test_extremeNativeRatiosLetterboxInsideTheCell() {
      // aspectFor() reports the true native ratio; arrange() packs within [.005, 20].
      first.sourceSize = Qt.size(3840, 60); wait(0)
      fuzzyCompare(cards.itemAt(0).aspect, 64, .001, "The card keeps the true ratio")
      assertContained(); assertInsideStage(); assertNoOverlap()
      const odd = cards.itemAt(0).surface
      fuzzyCompare(odd.width / odd.height, 64, .05, "A 3840x60 window letterboxes, it is never distorted")
      verify(odd.height < scene.placements[0].height, "A clamped cell is taller than the letterboxed frame")
      for (let i = 1; i < 3; i++) {
        verify(cards.itemAt(i).surface.width >= 100, "One strip window must not collapse the other cards")
        verify(cards.itemAt(i).surface.height >= 60, "One strip window must not collapse the other cards")
      }
      // The same in the other direction: a 1x1000 sliver is below the .005 bound.
      first.sourceSize = Qt.size(1, 1000); wait(0)
      fuzzyCompare(cards.itemAt(0).aspect, .001, .0001)
      assertContained(); assertInsideStage(); assertNoOverlap()
      verify(scene.placements[0].width >= 3, "The packed cell stays at the ratio bound")
      for (let i = 1; i < 3; i++) verify(cards.itemAt(i).surface.height >= 60)
      // Honest limit, pinned rather than papered over: the frame is what shell.qml:411
      // publishes as the click zone, so a window narrower than a five-hundredth of its
      // height letterboxes into a sub-pixel strip that is hard to hit. It is still
      // aspect-true, inside its cell, and it costs the other cards nothing.
      verify(cards.itemAt(0).surface.width > 0, "even the sliver is drawn, not collapsed")
      verify(cards.itemAt(0).surface.width < 1)
      // Ratios inside the bounds are packed exactly, with no letterboxing at all.
      first.sourceSize = Qt.size(100, 1000)
      third.sourceSize = Qt.size(8000, 1000); wait(0)
      assertFitted()
      first.sourceSize = Qt.size(0, 0); wait(0)
      fuzzyCompare(cards.itemAt(0).aspect, 1.6, .001, "No usable frame falls back to the IPC ratio")
      assertFitted()
    }
    // ---- titles -------------------------------------------------------------
    function test_titlesStayPlainBoundedAndNeverBlank() {
      const title = findChild(solo, "previewTitle")
      compare(title.textFormat, Text.PlainText)
      compare(title.elide, Text.ElideRight)
      compare(solo.label, "Solo")
      compare(title.text, "Solo")
      const names = [["org.gnome.Nautilus", "Nautilus"], ["org.gnome.Nautilus.", "Nautilus"],
                     ["...", "Window"], ["", "Window"], ["Alacritty", "Alacritty"], ["a.b.c", "c"]]
      for (let i = 0; i < names.length; i++) {
        scene.soloWindow = ({ address: "solo", title: "", lastIpcObject: { class: names[i][0], size: [1600, 1000] } })
        wait(0)
        compare(solo.appName, names[i][1], "Class " + JSON.stringify(names[i][0]) + " must name the card")
        compare(solo.label, names[i][1], "An empty title falls back to the app name, never to nothing")
      }
      const texts = ["한글 문서 제목", "日本語のウィンドウ", "Ελληνικά", "مرحبا بالعالم", "café Ⓐ🚀",
                     "e\u0301 combining", "<b>not markup</b>", "tab\there", "line\nbreak", " "]
      for (let i = 0; i < texts.length; i++) {
        scene.soloWindow = ({ address: "solo", title: texts[i], lastIpcObject: { class: "org.test.Solo", size: [1600, 1000] } })
        wait(0)
        compare(solo.label, texts[i], "The label is the raw title")
        compare(title.text, texts[i], "Plain text is never reinterpreted as markup")
        verify(title.width <= 360, "The title pill is bounded")
      }
      // An untrusted title cannot grow the card or escape the pill.
      let long = ""
      for (let i = 0; i < 400; i++) long += "overflowing title "
      scene.soloWindow = ({ address: "solo", title: long, lastIpcObject: { class: "org.test.Solo", size: [1600, 1000] } })
      wait(0)
      compare(solo.label, long)
      verify(title.width <= 360, "A 6800-character title is clamped to the pill width")
      verify(title.width <= solo.surface.width + 20)
      verify(title.truncated, "A title that does not fit must elide")
      compare(title.textFormat, Text.PlainText)
      // No window object at all: the card names nothing and throws nothing.
      scene.soloWindow = null; wait(0)
      compare(solo.appName, "Window")
      compare(solo.label, "")
      compare(title.text, "")
      scene.soloWindow = ({ address: "solo", title: "No ipc object" }); wait(0)
      compare(solo.appName, "Window")
      compare(solo.label, "No ipc object")
      fuzzyCompare(solo.aspect, 1.6, .001, "A window with no geometry still gets a usable card")
      // The placeholder heading elides too: the class is window-controlled.
      scene.soloCapture = null
      scene.soloWindow = ({ address: "solo", title: "", lastIpcObject: { class: long, size: [1600, 1000] } })
      wait(0)
      verify(findChild(solo, "previewPlaceholder").visible)
      const heading = findChild(solo, "previewHeading")
      compare(heading.text, solo.appName)
      compare(heading.textFormat, Text.PlainText)
      compare(heading.elide, Text.ElideRight)
      verify(heading.width <= solo.surface.width, "The placeholder heading stays inside the card")
      verify(heading.truncated)
    }
    // ---- one capture, two consumers ----------------------------------------
    function test_oneCaptureFeedsBothTheCardAndTheStrip() {
      scene.stripMembers = [{ address: "solo", title: "Solo", lastIpcObject: { size: [1600, 1000] } }]
      scene.extraCaptures = ({ solo: shared })
      wait(0)
      compare(solo.sharedCapture, shared)
      const tiles = tilesOf(strip)
      compare(tiles.length, 1)
      compare(tiles[0].sharedCapture, shared, "The strip thumbnail shares the card's capture object")
      const cardTexture = findChild(solo, "previewTexture")
      const stripTexture = findChild(tiles[0], "desktopTexture")
      verify(cardTexture !== null); verify(stripTexture !== null)
      compare(cardTexture.sourceItem, nativeFrame, "The card samples the one native source")
      compare(stripTexture.sourceItem, nativeFrame, "So does the strip, from the same object")
      compare(cardTexture.sourceItem, stripTexture.sourceItem)
      // Exactly one sampler per consumer, and neither consumer writes to the capture.
      let samplers = 0
      const nodes = descendants(solo)
      for (let i = 0; i < nodes.length; i++) if (nodes[i].objectName === "previewTexture") samplers++
      compare(samplers, 1, "One ShaderEffectSource per card, never a second copy")
      compare(shared.hasContent, true)
      compare(shared.fresh, true)
      compare(shared.allowStart, true)
      compare(shared.image, nativeFrame)
      compare(shared.sourceSize.width, 1600)
      compare(shared.sourceSize.height, 1000)
      // Both consumers agree on the ratio, from the capture and not from the IPC size.
      fuzzyCompare(solo.aspect, 1.6, .001)
      fuzzyCompare(tiles[0].width / tiles[0].height, 1.6, .01)
    }
    function test_captureVanishingMidSessionFallsBackToThePlaceholder() {
      scene.stripMembers = [{ address: "solo", title: "Solo", lastIpcObject: { size: [1600, 1000] } }]
      scene.extraCaptures = ({ solo: shared })
      wait(0)
      verify(solo.hasThumbnail)
      verify(findChild(solo, "previewTexture") !== null)
      compare(findChild(solo, "previewPlaceholder").visible, false)
      const tile = tilesOf(strip)[0]
      const tileWidth = tile.width
      // The stream drops its content: the sampler is released, not kept alive.
      shared.hasContent = false; wait(0)
      compare(solo.hasThumbnail, false)
      tryVerify(() => findChild(solo, "previewTexture") === null, 2000,
                "A card without content must not hold a texture")
      tryVerify(() => findChild(tile, "desktopTexture") === null, 2000,
                "Neither must the strip thumbnail")
      verify(findChild(solo, "previewPlaceholder").visible)
      compare(findChild(solo, "previewUnavailable").text, solo.unavailableText)
      fuzzyCompare(tile.width, tileWidth, .01, "The tile keeps its packed cell with no capture")
      // The whole capture object disappears mid-session.
      scene.soloCapture = null
      scene.extraCaptures = ({})
      wait(0)
      compare(solo.sharedCapture, null)
      compare(solo.hasThumbnail, false)
      compare(findChild(solo, "previewTexture"), null)
      compare(tilesOf(strip)[0].sharedCapture, null)
      compare(findChild(tilesOf(strip)[0], "desktopTexture"), null)
      verify(findChild(solo, "previewPlaceholder").visible)
      compare(solo.label, "Solo", "The card still names its window")
      fuzzyCompare(solo.aspect, 1.6, .001, "and falls back to the IPC ratio")
      // Coming back must not leave a second sampler behind.
      scene.soloCapture = shared
      scene.extraCaptures = ({ solo: shared })
      shared.hasContent = true
      wait(0)
      verify(solo.hasThumbnail)
      let samplers = 0
      const nodes = descendants(solo)
      for (let i = 0; i < nodes.length; i++) if (nodes[i].objectName === "previewTexture") samplers++
      compare(samplers, 1)
      compare(findChild(solo, "previewTexture").sourceItem, nativeFrame)
      // A capture that never had a frame behaves like no capture at all.
      scene.soloCapture = ({ sourceSize: Qt.size(0, 0), hasContent: false, hasFrame: false, image: null })
      wait(0)
      compare(solo.hasThumbnail, false)
      compare(findChild(solo, "previewTexture"), null)
      fuzzyCompare(solo.aspect, 1.6, .001)
    }
    function test_pausedBadgeOnlyShowsForARunnableStaleCapture() {
      const badge = findChild(solo, "previewPaused")
      shared.fresh = true; wait(0)
      compare(badge.visible, false, "A fresh capture is not paused")
      shared.fresh = false; wait(0)
      compare(badge.visible, true)
      // shell.qml sets allowStart false while closing, when no capture may restart.
      shared.allowStart = false; wait(0)
      compare(badge.visible, false, "A capture that may not start is not advertised as paused")
      shared.allowStart = true
      solo.showTitle = false; wait(0)
      compare(badge.visible, false, "The drag ghost carries no chrome")
      solo.showTitle = true
      shared.hasContent = false; wait(0)
      compare(badge.visible, false, "A placeholder card has no badge")
    }
    // ---- F-12: the texture request must not follow every animated pixel -----
    function test_textureRequestIsQuantisedAndBounded() {
      wait(0)
      const texture = findChild(solo, "previewTexture")
      verify(texture !== null)
      solo.width = 289; wait(0)
      // Value types read through a property are live references, so keep plain numbers.
      const baseWidth = texture.textureSize.width
      const baseHeight = texture.textureSize.height
      compare(baseWidth % 64, 0, "A quantised request never reallocates for one pixel")
      compare(baseHeight % 64, 0)
      // shell.qml animates x/y/width/height on open, drag and filter changes; every
      // distinct textureSize recreates the FBO, so the request must hold still.
      const widths = [289, 292.5, 295, 300.25, 305, 307]
      for (let i = 0; i < widths.length; i++) {
        solo.width = widths[i]; wait(0)
        compare(texture.textureSize.width, baseWidth, "Width " + widths[i] + " must reuse the same texture")
        compare(texture.textureSize.height, baseHeight, "Width " + widths[i] + " must reuse the same texture")
        verify(texture.textureSize.width >= Math.ceil(solo.surface.width * 2) - .01,
               "The request never drops below the 2x presentation size")
        verify(texture.textureSize.height >= Math.ceil(solo.surface.height * 2) - .01,
               "The request never drops below the 2x presentation size")
        verify(texture.textureSize.width <= nativeFrame.width, "and never past the native source")
        verify(texture.textureSize.height <= nativeFrame.height)
      }
      // It still tracks size, one 64 px step at a time.
      solo.width = 340; wait(0)
      verify(texture.textureSize.height > baseHeight, "A real size change still grows the texture")
      compare(texture.textureSize.height % 64, 0)
      solo.width = 3000; solo.height = 3000; wait(0)
      compare(texture.textureSize.width, nativeFrame.width, "The request is clamped to the native source")
      compare(texture.textureSize.height, nativeFrame.height)
      solo.width = 0.4; solo.height = 0.4; wait(0)
      verify(texture.textureSize.width >= 1, "and never collapses to zero")
      verify(texture.textureSize.height >= 1)
      // The strip tiles are quantised the same way: membership changes re-lay them out.
      scene.extraCaptures = ({ m0: shared, m1: shared, m2: shared })
      scene.stripMembers = [{ address: "m0", lastIpcObject: { size: [1600, 1000] } },
                            { address: "m1", lastIpcObject: { size: [1000, 1600] } },
                            { address: "m2", lastIpcObject: { size: [1600, 1000] } }]
      wait(0)
      const tiles = tilesOf(strip)
      compare(tiles.length, 3)
      for (let i = 0; i < tiles.length; i++) {
        const tileTexture = findChild(tiles[i], "desktopTexture")
        verify(tileTexture !== null)
        verify(tileTexture.textureSize.width % 64 === 0 || tileTexture.textureSize.width === nativeFrame.width)
        verify(tileTexture.textureSize.height % 64 === 0 || tileTexture.textureSize.height === nativeFrame.height)
        verify(tileTexture.textureSize.width >= Math.ceil(tiles[i].width * 2) - .01)
        verify(tileTexture.textureSize.height >= Math.ceil(tiles[i].height * 2) - .01)
        verify(tileTexture.textureSize.width <= nativeFrame.width)
        verify(tileTexture.textureSize.height <= nativeFrame.height)
      }
    }
    // ---- the compact desktop strip -----------------------------------------
    function test_stripPacksItsMembersInsideTheCompactCell() {
      compare(scene.stripMembers.length, 0)
      compare(strip.miniLayout.length, 0, "No members, no thumbnails")
      compare(tilesOf(strip).length, 0)
      verify(findChild(strip, "desktopLabel").visible, "An empty desktop is still labelled")
      const counts = [1, 2, 5, 12, 40, 117]
      for (let c = 0; c < counts.length; c++) {
        const members = []
        for (let i = 0; i < counts[c]; i++)
          members.push({ address: "m" + i, lastIpcObject: { size: [1600, 1000] } })
        scene.stripMembers = members; wait(0)
        const expected = Layout.arrange(members.map(() => 1.6), 132, 68, true)
        compare(strip.miniLayout.length, expected.length, counts[c] + " members must use the compact contract")
        compare(strip.miniLayout.length, counts[c])
        const tiles = tilesOf(strip)
        compare(tiles.length, counts[c])
        for (let i = 0; i < tiles.length; i++) {
          fuzzyCompare(tiles[i].x, 8 + expected[i].x, .01, "Tile " + i + " must sit in its packed cell")
          fuzzyCompare(tiles[i].y, 8 + expected[i].y, .01)
          fuzzyCompare(tiles[i].width, expected[i].width, .01)
          fuzzyCompare(tiles[i].height, expected[i].height, .01)
          verify(tiles[i].height >= 4, "The compact floor keeps a tile visible")
          verify(tiles[i].x >= 8 - .01 && tiles[i].x + tiles[i].width <= 8 + 132 + .01,
                 "Tile " + i + " must stay inside the 132 px thumbnail")
          verify(tiles[i].y >= 8 - .01 && tiles[i].y + tiles[i].height <= 8 + 68 + .01,
                 "Tile " + i + " must stay inside the 68 px thumbnail")
        }
        for (let i = 1; i < tiles.length; i++)
          verify(!(tiles[i - 1].x < tiles[i].x + tiles[i].width - .02 && tiles[i].x < tiles[i - 1].x + tiles[i - 1].width - .02 &&
                   tiles[i - 1].y < tiles[i].y + tiles[i].height - .02 && tiles[i].y < tiles[i - 1].y + tiles[i - 1].height - .02),
                 "Neighbouring tiles must not overlap")
      }
      // One window past the compact floor the strip refuses; tiles vanish, never
      // become invisible slivers, and nothing throws.
      const crowd = []
      for (let i = 0; i < 118; i++) crowd.push({ address: "m" + i, lastIpcObject: { size: [1600, 1000] } })
      scene.stripMembers = crowd; wait(0)
      compare(strip.miniLayout.length, 0)
      const tiles = tilesOf(strip)
      compare(tiles.length, 118)
      for (let i = 0; i < tiles.length; i++) {
        compare(tiles[i].width, 0)
        compare(tiles[i].height, 0)
      }
      verify(findChild(strip, "desktopLabel").visible)
    }
    function test_stripSurvivesAMissingOrUnsetModel() {
      scene.stripMembers = null; wait(0)
      compare(strip.memberList.length, 0)
      compare(strip.miniLayout.length, 0)
      compare(tilesOf(strip).length, 0)
      verify(findChild(strip, "desktopLabel").visible)
      scene.stripMembers = undefined; wait(0)
      compare(strip.miniLayout.length, 0)
      compare(tilesOf(strip).length, 0)
      // A member that disappeared this turn must not take the strip with it.
      scene.stripMembers = [{ address: "m0", lastIpcObject: { size: [1600, 1000] } }, null,
                            { address: "m2", lastIpcObject: { size: [1000, 1600] } }]
      wait(0)
      compare(strip.memberList.length, 3)
      compare(strip.miniLayout.length, 3)
      const tiles = tilesOf(strip)
      compare(tiles.length, 3)
      compare(tiles[1].sharedCapture, null, "A vanished member has no capture and no texture")
      compare(findChild(tiles[1], "desktopTexture"), null)
      verify(tiles[1].width > 0, "but it still holds its place in the grid")
      // A member with no IPC geometry falls back to the placeholder ratio.
      scene.stripMembers = [{ address: "m0" }]; wait(0)
      compare(strip.miniLayout.length, 1)
      fuzzyCompare(tilesOf(strip)[0].width / tilesOf(strip)[0].height, 1.6, .01)
    }
    function test_stripLabelAndRemoveAffordance() {
      const label = findChild(strip, "desktopLabel")
      compare(label.text, "Desktop 3", "The default label names the desktop id")
      compare(label.textFormat, Text.PlainText)
      compare(label.elide, Text.ElideRight)
      strip.label = "작업 공간 ✨"
      wait(0)
      compare(label.text, "작업 공간 ✨", "A renamed desktop shows its own name")
      strip.label = "<i>literal</i> markup"
      wait(0)
      compare(label.text, "<i>literal</i> markup")
      let long = ""
      for (let i = 0; i < 100; i++) long += "renamed workspace "
      strip.label = long; wait(0)
      compare(label.text, long)
      compare(label.width, strip.width, "A long name is elided, it never widens the strip")
      verify(label.truncated)
      strip.label = Qt.binding(function () { return "Desktop " + strip.desktopId })
      wait(0)
      compare(label.text, "Desktop 3")
      // The remove affordance is presentation only, and invisible unless allowed.
      compare(strip.removeButton.visible, false)
      scene.stripHovered = true; wait(0)
      compare(strip.removeButton.visible, false, "canRemove off must never publish a remove zone")
      scene.stripCanRemove = true; wait(0)
      compare(strip.removeButton.visible, true)
      scene.stripDropTarget = true; wait(0)
      compare(strip.removeButton.visible, false, "A drop target does not offer removal mid-drag")
      scene.stripDropTarget = false
      scene.stripHovered = false; wait(0)
      compare(strip.removeButton.visible, false, "Removal needs the pointer on the thumbnail")
    }
    // ---- presentation only --------------------------------------------------
    function test_previewComponentsNeverGrabInputOrLoadAFile() {
      scene.stripMembers = [{ address: "solo", lastIpcObject: { size: [1600, 1000] } }]
      scene.extraCaptures = ({ solo: shared })
      wait(0)
      const forbidden = ["MouseArea", "TapHandler", "DragHandler", "HoverHandler", "PointHandler",
                         "Flickable", "Process", "Timer", "Connections"]
      const roots = [solo, strip, cards.itemAt(0)]
      for (let r = 0; r < roots.length; r++) {
        const nodes = descendants(roots[r])
        verify(nodes.length > 1)
        for (let i = 0; i < nodes.length; i++) {
          const name = String(nodes[i])
          for (let f = 0; f < forbidden.length; f++)
            verify(name.indexOf(forbidden[f]) < 0,
                   "A preview must not contain " + forbidden[f] + " (found " + name + "): the overlay has one grab in DragSurface")
        }
      }
      // The strip's wallpaper is the only Image, and nothing in this suite feeds it a file.
      compare(strip.wallpaper, "")
      const nodes = descendants(strip)
      let images = 0
      for (let i = 0; i < nodes.length; i++)
        if (String(nodes[i]).indexOf("QQuickImage") >= 0) {
          images++
          compare(String(nodes[i].source), "", "No preview test may read an image from disk")
          compare(nodes[i].status, Image.Null)
        }
      compare(images, 1)
    }
  }
}
