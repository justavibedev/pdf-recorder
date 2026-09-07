import AppKit
import SwiftUI
import PDFRecorderCore

@MainActor struct TeleprompterText: NSViewRepresentable {
    let notes: String
    let fontSize: Double
    let speed: Double
    let running: Bool
    let page: Int
    func makeNSView(context: Context) -> PrompterScrollView { PrompterScrollView() }
    func updateNSView(_ view: PrompterScrollView, context: Context) {
        view.configure(notes: notes, fontSize: fontSize, speed: speed, running: running, page: page)
    }
}

@MainActor final class PrompterScrollView: NSScrollView {
    private let textView = NSTextView()
    private var scrollClock = PrompterClock()
    private var timer: Timer?
    private var running = false
    private var speed = 24.0
    private var page = -1
    private var previousWidth = 0.0
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false; hasVerticalScroller = true; autohidesScrollers = true
        textView.isEditable = false; textView.isSelectable = true; textView.drawsBackground = false
        textView.isRichText = false; textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("Teleprompter presenter notes")
        documentView = textView
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(notes: String, fontSize: Double, speed: Double, running: Bool, page: Int) {
        if textView.string != notes || textView.font?.pointSize != CGFloat(fontSize) {
            textView.string = notes; textView.font = .systemFont(ofSize: fontSize); textView.textColor = .labelColor
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
            textView.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: textView.string.utf16.count))
            needsLayout = true
        }
        if self.page != page {
            self.page = page; scrollClock.scroll(to: 0); contentView.scroll(to: .zero); reflectScrolledClipView(contentView)
        }
        self.speed = speed
        if self.running != running { self.running = running; updateTimer() }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTimer() }
    override func layout() {
        super.layout()
        let width = contentSize.width
        if width != previousWidth || textView.frame.width != width {
            previousWidth = width
            textView.setFrameSize(NSSize(width: width, height: max(contentSize.height, textView.frame.height)))
        }
        textView.textContainerInset = NSSize(width: 14, height: contentSize.height * 0.32)
        textView.textContainer?.containerSize = NSSize(width: max(1, width - 28), height: CGFloat.greatestFiniteMagnitude)
        if let container = textView.textContainer, let manager = textView.layoutManager {
            manager.ensureLayout(for: container)
            let height = max(contentSize.height, manager.usedRect(for: container).height + contentSize.height * 0.8)
            if abs(textView.frame.height - height) > 0.5 { textView.setFrameSize(NSSize(width: width, height: height)) }
        }
    }
    private func updateTimer() {
        timer?.invalidate(); timer = nil
        scrollClock.scroll(to: contentView.bounds.minY)
        guard running, window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let view = self else { return }
            Task { @MainActor in view.advance() }
        }
    }
    private func advance() {
        let actual = contentView.bounds.minY
        // Manual wheel/trackpad scrolling establishes a new anchor, with no snap back.
        if abs(actual - scrollClock.offset) > 1 { scrollClock.scroll(to: actual) }
        let offset = scrollClock.update(now: ProcessInfo.processInfo.systemUptime, running: running,
                                        speed: speed, maximum: max(0, textView.frame.height - contentSize.height))
        contentView.scroll(to: NSPoint(x: 0, y: offset)); reflectScrolledClipView(contentView)
    }
}
