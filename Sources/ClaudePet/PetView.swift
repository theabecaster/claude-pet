import AppKit

// MARK: - PetView (the prominent / primary pet)

final class PetView: NSView {
    var sprite: NSImage?
    var cfg = Frames()
    var anim = "idle"
    var frameIndex = 0
    var bubbleLabel: String?
    var bubbleDot: NSColor?
    var oneShotFallback: String?
    var detail: String?          // verb / reason for the status pill ("editing main.swift", "rate limited"…)
    var elapsedText: String?     // time-in-state, e.g. "12s"
    var ctxProgress: Double?     // 0…1 context used; drawn as a progress fill on the pill's border
    var baseState = "idle"       // the true session state, so a one-shot poke returns to it

    // Progressive disclosure: at rest the overlay is JUST the pet. Pointing at it — or
    // pinning — fades in the name + status pill, which then linger a few seconds after
    // the pointer leaves so they stay readable, before fading back to just the pet.
    var hovering = false         // pinned || pointer over the pet
    private var revealAmount = 0.0   // 0…1 eased; 1 = fully shown
    private var lingerTicks = 0      // frames to hold the reveal up after hover ends
    private let lingerHold = 90      // ~3s at 30fps
    // True while the name/pill are (even partly) shown — the container grows to fit them
    // so the at-rest overlay can stay tight to the pet.
    var isRevealed: Bool { hovering || revealAmount > 0.01 }

    private var ticks = 0
    private var spriteAccum = 0.0
    private var oneShotElapsed = 0.0
    private var pokeUntil = 0.0   // ticks-based: extra happy bounce window after a tap
    private var idleTicks = 0     // how long we've sat in idle → drives the sleep animation
    private let sleepAfterTicks = 45 * 30   // doze off after ~45s idle
    private var phase: Double { Double(ticks) / 30.0 }
    // The built-in mascot dozes off after a calm idle stretch (mascot-only, like the
    // other code-drawn motion; a custom sprite keeps its own idle frames).
    private var sleeping: Bool { sprite == nil && anim == "idle" && idleTicks > sleepAfterTicks }

    // A friendly reaction when the user taps the pet: a happy hop now, settling back
    // into whatever the session is actually doing. Purely cosmetic.
    func poke() {
        let d = describe("jumping")
        anim = d.anim; bubbleLabel = "hi!"; bubbleDot = Theme.coral
        frameIndex = 0; spriteAccum = 0; oneShotElapsed = 0
        oneShotFallback = baseState        // fall back to the real state, not the generic default
        pokeUntil = Double(ticks) + 21     // ~0.7s of extra bounce for the code-drawn mascot
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // container handles mouse
    private func anims() -> [String: [Int]] { cfg.animations ?? codexAnimations() }

    private func currentFrameNumber() -> Int {
        let list = anims()[anim] ?? [0]
        guard !list.isEmpty else { return 0 }
        return list[frameIndex % list.count]
    }

    func setState(_ s: String) {
        let d = describe(s)
        if anim != d.anim { frameIndex = 0; spriteAccum = 0; oneShotElapsed = 0 }
        anim = d.anim; bubbleLabel = d.label; bubbleDot = d.dot; oneShotFallback = d.oneShot
        needsDisplay = true
    }

    // Calm states animate slowly; attention states a touch livelier.
    private func stateFPS() -> Double {
        switch anim {
        case "idle": return 3
        case "running", "running-right", "running-left", "review": return 4
        case "waiting": return 7
        case "failed": return 9
        case "waving": return 10
        case "jumping": return 12
        default: return 6
        }
    }

    func advance() {
        ticks += 1
        idleTicks = (anim == "idle") ? idleTicks + 1 : 0
        // Reveal: fade in while hovering, hold for `lingerHold` after the pointer
        // leaves (so the panel stays usable), then fade out slowly.
        if hovering { lingerTicks = lingerHold }
        if hovering || lingerTicks > 0 {
            if !hovering { lingerTicks -= 1 }
            revealAmount = min(1, revealAmount + 0.34)   // snappy fade-in (~3 frames)
        } else {
            revealAmount = max(0, revealAmount - 0.22)   // quick fade-out
        }
        if sprite != nil {
            spriteAccum += stateFPS() / 30.0
            while spriteAccum >= 1 {
                spriteAccum -= 1
                let list = anims()[anim] ?? [0]
                if list.count > 1 {
                    frameIndex += 1
                    if frameIndex >= list.count {
                        if let fb = oneShotFallback { setState(fb) } else { frameIndex = 0 }
                    }
                }
            }
        } else if oneShotFallback != nil {
            oneShotElapsed += 1.0 / 30.0
            if oneShotElapsed > 0.7, let fb = oneShotFallback { setState(fb) }
        }
        needsDisplay = true
    }

    // Attention-keyed motion: working/idle barely move; waiting bobs + red halo; failed shakes.
    private func motion() -> (dx: CGFloat, dy: CGFloat, ring: CGFloat) {
        let p = phase
        if sleeping { return (0, CGFloat(sin(p * 2 * .pi * 0.12)) * 1.0, 0) }   // slow breathing
        var m: (dx: CGFloat, dy: CGFloat, ring: CGFloat)
        switch anim {
        case "waiting":
            let s = (sin(p * 2 * .pi * 1.1) + 1) / 2
            m = (0, CGFloat(s) * 7, CGFloat(s))
        case "failed":
            m = (CGFloat(sin(p * 2 * .pi * 6)) * 2.5, 0, 0)
        case "review", "jumping", "done", "ready":
            m = (0, CGFloat((sin(p * 2 * .pi * 0.8) + 1) / 2) * 3, 0)
        case "idle":
            m = (0, CGFloat(sin(p * 2 * .pi * 0.25)) * 1.2, 0)
        default:
            m = (0, 0, 0)                                      // working: still & busy
        }
        if Double(ticks) < pokeUntil {                        // snappy hop right after a tap
            let t = (pokeUntil - Double(ticks)) / 21          // 1 -> 0 over the window
            m.dy += CGFloat(abs(sin(t * .pi * 2))) * CGFloat(t) * 10
        }
        return m
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set(); dirtyRect.fill()
        NSGraphicsContext.current?.imageInterpolation = .none

        let fw = CGFloat(cfg.frameWidth), fh = CGFloat(cfg.frameHeight)
        let scale = CGFloat(cfg.scale)
        let drawW = fw * scale, drawH = fh * scale
        let baseX = (bounds.width - drawW) / 2, baseY: CGFloat = 12
        // Code-drawn motion (bob/shake) and the attention halo are part of the
        // built-in mascot's "attention budget" look. A custom sprite ships its own
        // per-state animation, so we render it flat — no bob, no shake, no halo —
        // and let the sprite's own frames carry the context and look its author intended.
        let m = sprite == nil ? motion() : (dx: CGFloat(0), dy: CGFloat(0), ring: CGFloat(0))
        let dest = NSRect(x: baseX + m.dx, y: baseY + m.dy, width: drawW, height: drawH)

        if m.ring > 0 {                                        // pulsing attention halo
            let grow = 3 + m.ring * 6
            let rr = dest.insetBy(dx: -grow, dy: -grow)
            let ring = NSBezierPath(roundedRect: rr, xRadius: rr.width * 0.3, yRadius: rr.height * 0.3)
            Theme.red.withAlphaComponent(0.12 + 0.4 * m.ring).setStroke()
            ring.lineWidth = 2 + 2 * m.ring; ring.stroke()
        }

        if let img = sprite {
            let perRow = max(1, Int(img.size.width.rounded()) / cfg.frameWidth)
            let n = currentFrameNumber()
            let col = n % perRow, row = n / perRow
            let srcY = img.size.height - CGFloat(row + 1) * fh
            img.draw(in: dest, from: NSRect(x: CGFloat(col) * fw, y: srcY, width: fw, height: fh),
                     operation: .sourceOver, fraction: 1.0)
        } else {
            drawBuddy(in: dest, accent: accentFor(anim), anim: anim, phase: phase, sleeping: sleeping)
            if sleeping { drawZzz(near: dest) }
        }

        // At rest the overlay is JUST the pet. On reveal (hover/pin), the status pill
        // fades in above it (the session name lives in the picker, not here). The pill's
        // border doubles as the context gauge: green→amber→red as the context fills.
        guard revealAmount > 0.02 else { return }
        let a = CGFloat(revealAmount)
        let textRect = NSRect(x: baseX, y: baseY, width: drawW, height: drawH)
        if let label = pillText() {
            drawThought(label, dot: bubbleDot, petTop: textRect.maxY, alpha: a, progress: ctxProgress)
        }
    }

    // A few drifting "z"s above a dozing mascot.
    private func drawZzz(near rect: NSRect) {
        let base = NSPoint(x: rect.maxX - rect.width * 0.10, y: rect.maxY - rect.height * 0.18)
        for i in 0..<3 {
            let t = (phase * 0.5 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)   // 0→1 loop
            let size = 9 + CGFloat(i) * 3
            let x = base.x + CGFloat(t) * 14, y = base.y + CGFloat(t) * 20
            let alpha = (1 - t) * 0.85
            let f = NSFont(name: "Menlo-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
            let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: Theme.coral.withAlphaComponent(CGFloat(alpha))]
            ("z" as NSString).draw(at: NSPoint(x: x, y: min(y, bounds.height - size)), withAttributes: a)
        }
    }

    // What the pet is "thinking", in plain pet-voice copy that reads naturally in the
    // bubble — not the raw hook text. Running states keep the concrete activity
    // ("editing main.swift"); the rest map to a short, human phrase. Time-in-state is
    // appended so you can see how long it's been like this.
    private func pillText() -> String? {
        let phrase: String?
        switch anim {
        case "waiting":
            phrase = "answer Claude"                       // it needs your input / permission
        case "failed":
            phrase = detail.map { "stopped — \($0)" } ?? "Claude stopped"
        case "review", "jumping", "done", "ready":
            phrase = "all done — your turn"
        case "waving":
            phrase = "hey there"
        case "running", "running-left", "running-right":
            phrase = detail ?? "working…"                  // detail = "editing main.swift", "running npm"…
        default:
            phrase = detail ?? bubbleLabel
        }
        guard var base = phrase else { return nil }
        if let e = elapsedText { base += "  ·  " + e }
        return base
    }

    // Word-wrap to at most `maxLines`; the final line is ellipsized if it still overflows.
    private func wrap(_ text: String, font: NSFont, maxW: CGFloat, maxLines: Int) -> [String] {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width }
        var lines: [String] = []
        var cur = ""
        for word in text.split(separator: " ").map(String.init) {
            let cand = cur.isEmpty ? word : cur + " " + word
            if width(cand) <= maxW || cur.isEmpty { cur = cand } else { lines.append(cur); cur = word }
        }
        if !cur.isEmpty { lines.append(cur) }
        if lines.count <= maxLines { return lines }
        var kept = Array(lines.prefix(maxLines - 1))
        kept.append(truncated(lines[(maxLines - 1)...].joined(separator: " "), font: font, maxW: maxW))
        return kept
    }


    // The status as a THOUGHT BUBBLE floating over the pet: a soft rounded cloud with
    // two little trailing puffs leading down to the pet's head — visually distinct from
    // the squared-off session picker. The bubble's border is still the context gauge
    // (a clockwise green→amber→red progress stroke).
    @discardableResult
    private func drawThought(_ label: String, dot: NSColor?, petTop: CGFloat, alpha: CGFloat = 1, progress: Double? = nil) -> CGFloat {
        let font: NSFont = NSFont(name: "Menlo", size: 11) ?? NSFont.boldSystemFont(ofSize: 11)
        let dotR: CGFloat = 4, padX: CGFloat = 9, padY: CGFloat = 5, gap: CGFloat = 6
        let dotW: CGFloat = dot != nil ? dotR * 2 + gap : 0
        let maxTextW = bounds.width - 8 - padX * 2 - dotW
        let lines = wrap(label, font: font, maxW: maxTextW, maxLines: 2)
        let tAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.termFG.withAlphaComponent(alpha)]
        let sizes = lines.map { ($0 as NSString).size(withAttributes: tAttrs) }
        let textW = sizes.map { $0.width }.max() ?? 0
        let lineH = font.ascender - font.descender + 2
        let textH = lineH * CGFloat(lines.count)
        let bw = padX * 2 + dotW + textW
        let bh = padY * 2 + max(textH, dotR * 2)

        // Trailing puffs occupy a small gap between the pet's head and the bubble.
        let trailH: CGFloat = 15
        let bx = min(max(4, bounds.midX - bw / 2), bounds.width - bw - 4)
        let br = NSRect(x: bx, y: petTop + trailH, width: bw, height: bh)
        let radius = min(bh / 2, 16)   // soft, cloud-like — not the picker's squared corners

        let bg = Theme.termBG.withAlphaComponent(0.95 * alpha)
        let edge = Theme.coral.withAlphaComponent(0.7 * alpha)

        // Two trailing puffs rising from the pet's TOP-RIGHT up toward the bubble
        // (like a thought drifting off the side of its head, not straight up the middle).
        let petW = CGFloat(cfg.frameWidth) * CGFloat(cfg.scale)
        let rightX = bounds.midX + petW * 0.24
        let puffs: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
            (rightX + 8, petTop + 9,   3.4),   // upper, larger (toward the bubble) — leans up-right
            (rightX,     petTop + 2.5, 2.1),   // lower, smaller (at the pet's head)
        ]
        let puffPaths = puffs.map { p in
            NSBezierPath(ovalIn: NSRect(x: p.x - p.r, y: p.y - p.r, width: p.r * 2, height: p.r * 2))
        }
        let bubble = NSBezierPath(roundedRect: br, xRadius: radius, yRadius: radius)

        // Soft drop shadow under the whole thought so it floats above the desktop.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.33 * alpha)
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.shadowBlurRadius = 6
        shadow.set()
        bg.setFill(); puffPaths.forEach { $0.fill() }
        bg.setFill(); bubble.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Puff outlines (no shadow), matching the bubble edge.
        for path in puffPaths { edge.setStroke(); path.lineWidth = 1; path.stroke() }
        if let p = progress {
            // Border = context gauge: dim full-perimeter track + a fraction drawn over it.
            let track = NSBezierPath(roundedRect: br, xRadius: radius, yRadius: radius)
            track.lineWidth = 1.5
            Theme.termFG.withAlphaComponent(0.20 * alpha).setStroke(); track.stroke()
            let f = max(0, min(1, p))
            if f > 0.001 {
                let perim = 2 * ((br.width - 2 * radius) + (br.height - 2 * radius)) + 2 * .pi * radius
                let prog = NSBezierPath(roundedRect: br, xRadius: radius, yRadius: radius)
                prog.lineWidth = 1.8; prog.lineCapStyle = .round
                prog.setLineDash([perim * CGFloat(f), perim], count: 2, phase: 0)
                let col: NSColor = f >= 0.9 ? Theme.red
                    : (f >= 0.75 ? NSColor(red: 0.92, green: 0.62, blue: 0.22, alpha: 1) : Theme.green)
                col.withAlphaComponent(alpha).setStroke(); prog.stroke()
            }
        } else {
            edge.setStroke(); bubble.lineWidth = 1; bubble.stroke()
        }

        if let d = dot {
            d.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: br.minX + padX, y: br.midY - dotR, width: dotR * 2, height: dotR * 2)).fill()
        }
        let textX = br.minX + padX + dotW
        var ly = br.maxY - padY - (sizes.first?.height ?? lineH)
        for line in lines {
            (line as NSString).draw(at: NSPoint(x: textX, y: ly), withAttributes: tAttrs)
            ly -= lineH
        }
        return br.maxY
    }
}
