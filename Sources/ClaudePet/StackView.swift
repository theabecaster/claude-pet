import AppKit

// MARK: - StackView
// The selected session's pet shows large in the corner. All sessions appear in a
// fixed-order list above it (selected one highlighted). Order is STABLE — it only
// changes when the user drags a row. Click a row to select; scroll to step
// through; drag the pet (or empty area) to move the whole widget.

struct SessionItem { let id: String; let state: String; let label: String; var detail: String? = nil }

final class StackView: NSView {
    let primary = PetView(frame: .zero)
    var items: [SessionItem] = []          // ALL sessions, in stable display order
    var selectedID: String?
    var onSelect: ((String) -> Void)?
    var onReorder: (([String]) -> Void)?
    var onCycle: ((Int) -> Void)?
    var onPetTapped: (() -> Void)?
    var onWindowMoved: (() -> Void)?        // user dragged the widget -> re-anchor the pet
    var pinDetails = false                  // keep the details panel open regardless of hover
    var petHovered = false                  // mouse currently over the pet region
    var listExpanded = false                // picker: collapsed (active session only) vs all sessions

    let W: CGFloat = 232
    // The pet panel is short at rest (JUST the pet) and grows when the status pill
    // reveals on hover, fitting up to a 2-line pill.
    var PETH: CGFloat { primary.isRevealed ? 168 : 112 }
    let rowH: CGFloat = 26, innerPad: CGFloat = 7, margin: CGFloat = 8, gap: CGFloat = 5
    private var downInWin = NSPoint.zero    // mouse-down point in view coords
    private var lastScreen = NSPoint.zero   // for window dragging (screen coords)
    private var moved: CGFloat = 0
    private var dragIndex: Int? = nil       // row being dragged (reorder)
    private var dragging = false            // a reorder drag is in progress
    private var dragCursorY: CGFloat = 0    // cursor Y so the lifted row follows
    private var windowDrag = false
    private var hoveredRow = -1
    private var hoverRowSince = Date()       // when the current row hover began (for dwell reveal)
    private var scrollAccum: CGFloat = 0

    // The picker is part of the reveal: hidden at rest, shown while hovering/pinned. It
    // COLLAPSES to just the active session by default and EXPANDS to all sessions on a
    // click (only when there's more than one). Names live in the picker — the pet shows
    // no caption of its own.
    var showList: Bool { !items.isEmpty && primary.isRevealed }
    var expandable: Bool { items.count > 1 }
    private var rowCount: Int { listExpanded ? items.count : 1 }
    private var selectedItem: SessionItem? { items.first { $0.id == selectedID } ?? items.first }
    var isReordering: Bool { dragging }    // true mid-drag: sync() must not clobber `items`

    // Eased 0…1 expand progress (0 = collapsed to the active row, 1 = all rows). The
    // VISUAL panel height interpolates on this so the box grows/shrinks smoothly and the
    // two layouts cross-fade; hit-testing still uses the logical `rowCount` (final state).
    private var expandAmount: CGFloat = 0
    // Continuous row count for the panel height: 1 row, easing up to all rows.
    private var visibleRows: CGFloat { 1 + CGFloat(max(0, items.count - 1)) * expandAmount }
    // Drive the expand/collapse ease one frame; returns true while still animating.
    @discardableResult func advanceExpand() -> Bool {
        let target: CGFloat = (listExpanded && expandable) ? 1 : 0
        if abs(expandAmount - target) < 0.001 { expandAmount = target; return false }
        expandAmount += (target - expandAmount) * 0.3   // exponential ease toward target
        needsDisplay = true
        return true
    }

    override init(frame f: NSRect) { super.init(frame: f); addSubview(primary) }
    required init?(coder: NSCoder) { fatalError() }

    func listPanelH() -> CGFloat { showList ? visibleRows * rowH + innerPad * 2 : 0 }
    func desiredHeight() -> CGFloat { margin * 2 + PETH + (showList ? gap + listPanelH() : 0) }
    // Session picker sits BELOW the pet (bubble above, pet centred, picker beneath) for a
    // balanced stack; the pet stays put while the picker reveals downward (see applyWindowFrame).
    func listOffset() -> CGFloat { showList ? listPanelH() + gap : 0 }
    func panelRect() -> NSRect { NSRect(x: margin, y: margin, width: W - margin * 2, height: listPanelH()) }
    func layoutContents() {
        primary.frame = NSRect(x: 0, y: margin + listOffset(), width: W, height: PETH)   // pet above the picker
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    // Index into the VISIBLE rows (0..<rowCount). Collapsed → only row 0 (active session).
    private func rowIndex(at p: NSPoint, clamp: Bool = false) -> Int? {
        guard showList else { return nil }
        let panel = panelRect()
        if !clamp && !panel.contains(p) { return nil }
        var i = Int((panel.maxY - innerPad - p.y) / rowH)
        if clamp { i = max(0, min(rowCount - 1, i)) }
        return (i >= 0 && i < rowCount) ? i : nil
    }

    // A downward (or upward) chevron centred at (cx, cy).
    private func drawChevron(down: Bool, cx: CGFloat, cy: CGFloat, w: CGFloat, color: NSColor) {
        let p = NSBezierPath(); p.lineWidth = 1.4; p.lineCapStyle = .round; p.lineJoinStyle = .round
        let h = w * 0.55
        let yTip = down ? cy - h / 2 : cy + h / 2, yArm = down ? cy + h / 2 : cy - h / 2
        p.move(to: NSPoint(x: cx - w / 2, y: yArm))
        p.line(to: NSPoint(x: cx, y: yTip))
        p.line(to: NSPoint(x: cx + w / 2, y: yArm))
        color.setStroke(); p.stroke()
    }

    private func drawRow(_ it: SessionItem, in row: NSRect, selected: Bool, hovered: Bool, lifted: Bool,
                         showDetail: Bool, draggable: Bool, rightInset: CGFloat, font: NSFont) {
        let inner = row.insetBy(dx: 3, dy: 1)
        if lifted {                                            // the row being dragged: pops out
            Theme.termBG.setFill()
            let p = NSBezierPath(roundedRect: inner, xRadius: 6, yRadius: 6); p.fill()
            Theme.coral.setStroke(); p.lineWidth = 1.5; p.stroke()
        } else if selected {
            Theme.coral.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: inner, xRadius: 6, yRadius: 6).fill()
            Theme.coral.setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: 3, height: inner.height), xRadius: 1.5, yRadius: 1.5).fill()
        } else if hovered {
            Theme.coral.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: inner, xRadius: 6, yRadius: 6).fill()
        }
        let nameX: CGFloat
        if draggable {
            // grip dots — signals the row is draggable (brighter on hover/lift)
            NSColor.white.withAlphaComponent(hovered || lifted ? 0.55 : 0.28).setFill()
            for r in 0..<2 { for dy in [-3.5, 0.0, 3.5] {
                NSBezierPath(ovalIn: NSRect(x: row.minX + 8 + CGFloat(r) * 3.2, y: row.midY + CGFloat(dy) - 0.85, width: 1.7, height: 1.7)).fill()
            } }
            nameX = row.minX + 32
        } else {
            nameX = row.minX + 14
        }
        let dotR: CGFloat = 4
        accentFor(it.state).setFill()
        NSBezierPath(ovalIn: NSRect(x: nameX - 12, y: row.midY - dotR, width: dotR * 2, height: dotR * 2)).fill()
        // Activity detail reveals on the right after a hover-dwell; the name truncates
        // to leave it room, so the two never overlap. `rightInset` reserves room for the
        // expand chevron on the collapsed row.
        var nameMaxW = row.maxX - 12 - rightInset - nameX
        if showDetail, let d = it.detail, !d.isEmpty {
            let stStr = truncated(d, font: font, maxW: 120) as NSString
            let stAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.termFG.withAlphaComponent(0.5)]
            let stSize = stStr.size(withAttributes: stAttrs)
            let stX = row.maxX - 12 - rightInset - stSize.width
            stStr.draw(at: NSPoint(x: stX, y: row.midY - stSize.height / 2), withAttributes: stAttrs)
            nameMaxW = stX - nameX - 10
        }
        let nmCol = selected ? Theme.termFG : Theme.termFG.withAlphaComponent(0.85)
        let nmAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: nmCol]
        let nm = truncated(it.label, font: font, maxW: max(20, nameMaxW)) as NSString
        nm.draw(at: NSPoint(x: nameX, y: row.midY - nm.size(withAttributes: nmAttrs).height / 2), withAttributes: nmAttrs)
    }

    override func draw(_ r: NSRect) {
        NSColor.clear.set(); r.fill()
        guard showList else { return }
        let panel = panelRect()
        let bg = NSBezierPath(roundedRect: panel, xRadius: 10, yRadius: 10)
        Theme.termBG.setFill(); bg.fill()
        Theme.coral.withAlphaComponent(0.7).setStroke(); bg.lineWidth = 1; bg.stroke()

        let dwell = Date().timeIntervalSince(hoverRowSince) > 0.45
        let font = NSFont(name: "Menlo", size: 10) ?? .systemFont(ofSize: 10)
        let t = expandAmount                       // 0 = collapsed, 1 = expanded, eased
        let cg = NSGraphicsContext.current!.cgContext

        // Clip to the (animated) panel so rows mask in/out as the box grows/shrinks.
        NSGraphicsContext.current?.saveGraphicsState()
        bg.addClip()

        // Collapsed layer — just the active session + an expand affordance (count +
        // chevron). Fades out as the box expands.
        if t < 0.999, let it = selectedItem {
            cg.saveGState(); cg.setAlpha(1 - t)
            let rowY = panel.maxY - innerPad - rowH
            let row = NSRect(x: panel.minX, y: rowY, width: panel.width, height: rowH)
            let inset: CGFloat = expandable ? 30 : 0
            drawRow(it, in: row, selected: true, hovered: hoveredRow == 0 && !listExpanded, lifted: false,
                    showDetail: false, draggable: false, rightInset: inset, font: font)
            if expandable {
                let n = "\(items.count)" as NSString
                let nAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.coral.withAlphaComponent(0.9)]
                let ns = n.size(withAttributes: nAttrs)
                n.draw(at: NSPoint(x: row.maxX - 26 - ns.width, y: row.midY - ns.height / 2), withAttributes: nAttrs)
                drawChevron(down: true, cx: row.maxX - 15, cy: row.midY, w: 8, color: Theme.coral.withAlphaComponent(0.9))
            }
            cg.restoreGState()
        }

        // Expanded layer — all sessions (full select / scroll / drag) + a collapse
        // chevron. Fades in as the box expands; the rows beyond the first reveal in the
        // growing space below.
        if t > 0.001 {
            cg.saveGState(); cg.setAlpha(t)
            for (i, it) in items.enumerated() {
                if dragging && i == dragIndex { continue }      // leave a gap; drawn floating below
                let rowY = panel.maxY - innerPad - CGFloat(i + 1) * rowH
                let row = NSRect(x: panel.minX, y: rowY, width: panel.width, height: rowH)
                let isHov = !dragging && i == hoveredRow && listExpanded
                let inset: CGFloat = i == 0 ? 22 : 0
                drawRow(it, in: row, selected: it.id == selectedID, hovered: isHov, lifted: false,
                        showDetail: isHov && dwell, draggable: true, rightInset: inset, font: font)
            }
            drawChevron(down: false, cx: panel.maxX - 15, cy: panel.maxY - innerPad - rowH / 2, w: 8,
                        color: Theme.coral.withAlphaComponent(0.9))
            if dragging, let di = dragIndex {                   // the lifted row follows the cursor
                let cy = min(max(dragCursorY, panel.minY + rowH / 2), panel.maxY - rowH / 2)
                let row = NSRect(x: panel.minX, y: cy - rowH / 2, width: panel.width, height: rowH)
                drawRow(items[di], in: row, selected: items[di].id == selectedID, hovered: false, lifted: true,
                        showDetail: false, draggable: true, rightInset: 0, font: font)
            }
            cg.restoreGState()
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func mouseEntered(with e: NSEvent) { updatePetHover(true) }
    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let i = rowIndex(at: p) ?? -1
        if i != hoveredRow { hoveredRow = i; hoverRowSince = Date(); needsDisplay = true }
        updatePetHover(true)
    }
    override func mouseExited(with e: NSEvent) {
        if hoveredRow != -1 { hoveredRow = -1; needsDisplay = true }
        updatePetHover(false)
    }

    // Pointing anywhere at the widget (or pinning) reveals the pill + the session
    // picker; leaving hides them again (after the pet's linger). Using the whole widget
    // — not just the pet — keeps the revealed picker from collapsing under the pointer.
    func updatePetHover(_ over: Bool) {
        petHovered = over
        let target = pinDetails || petHovered
        if primary.hovering != target { primary.hovering = target }
    }

    private var pressedRow: Int? = nil       // visible row pressed on mouseDown
    override func mouseDown(with e: NSEvent) {
        downInWin = convert(e.locationInWindow, from: nil)
        lastScreen = NSEvent.mouseLocation; moved = 0
        if let i = rowIndex(at: downInWin) {
            pressedRow = i
            dragIndex = listExpanded ? i : nil    // reorder only when expanded
            windowDrag = false
        } else { pressedRow = nil; dragIndex = nil; windowDrag = true }   // pet/empty -> move the widget
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        moved = max(moved, hypot(p.x - downInWin.x, p.y - downInWin.y))
        if windowDrag {
            let now = NSEvent.mouseLocation
            if let win = window { var o = win.frame.origin; o.x += now.x - lastScreen.x; o.y += now.y - lastScreen.y; win.setFrameOrigin(o) }
            lastScreen = now
            onWindowMoved?()                    // re-anchor the pet to the dragged position
        } else if listExpanded, let di = dragIndex, moved > 3 {   // reorder this row live
            dragging = true; dragCursorY = p.y
            if let t = rowIndex(at: p, clamp: true), t != di {
                let it = items.remove(at: di); items.insert(it, at: t); dragIndex = t
            }
            needsDisplay = true
        }
    }
    override func mouseUp(with e: NSEvent) {
        if windowDrag {
            if moved <= 3, primary.frame.contains(downInWin) { onPetTapped?() }   // tap the pet -> react
        } else if let pr = pressedRow {
            if listExpanded {
                if moved > 3 { onReorder?(items.map { $0.id }) }                  // committed a reorder
                else if pr < items.count { onSelect?(items[pr].id); listExpanded = false }   // pick + collapse
            } else if expandable {
                listExpanded = true                                              // collapsed click -> expand
            }
        }
        pressedRow = nil; dragIndex = nil; windowDrag = false; dragging = false; needsDisplay = true
    }

    // Scroll over the widget to step the selection through sessions (works collapsed too).
    override func scrollWheel(with e: NSEvent) {
        guard showList, expandable else { return }
        scrollAccum += e.scrollingDeltaY
        if scrollAccum > 6 { onCycle?(-1); scrollAccum = 0 }
        else if scrollAccum < -6 { onCycle?(1); scrollAccum = 0 }
    }
}
