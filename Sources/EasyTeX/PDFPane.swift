import SwiftUI
import PDFKit

/// Wraps the PDFView so the rest of the app can talk to it without caring about view lifecycles.
@MainActor
final class PDFController: NSObject {
    weak var view: PDFView?
    /// Called on double-click with (page 1-based, x, y from top) in PDF points.
    var onSourceJump: ((Int, Double, Double) -> Void)?

    /// Shows a new document but keeps the reader's scroll position and zoom (the PDF is replaced after every compile).
    func setDocument(_ doc: PDFDocument?) {
        guard let view, view.document !== doc else { return }
        var restore: (index: Int, point: CGPoint)?
        if let old = view.document, let dest = view.currentDestination, let page = dest.page {
            restore = (old.index(for: page), dest.point)
        }
        let scale = view.scaleFactor
        let wasAuto = view.autoScales
        view.document = doc
        if !wasAuto {
            view.autoScales = false
            view.scaleFactor = scale
        }
        if let doc, let restore, restore.index < doc.pageCount, let page = doc.page(at: restore.index) {
            DispatchQueue.main.async { view.go(to: PDFDestination(page: page, at: restore.point)) }
        }
    }

    func goTo(page: Int, x: Double, yFromTop: Double) {
        guard let view, let doc = view.document, page >= 1, page <= doc.pageCount, let p = doc.page(at: page - 1) else { return }
        let box = p.bounds(for: .mediaBox)
        let target = CGPoint(x: max(box.minX, box.minX + x - 40), y: min(box.maxY, box.maxY - yFromTop + 80))
        view.go(to: PDFDestination(page: p, at: target))
    }

    func zoomIn() { view?.autoScales = false; view?.zoomIn(nil) }
    func zoomOut() { view?.autoScales = false; view?.zoomOut(nil) }
    func fitWidth() { view?.autoScales = true }

    @objc func doubleClick(_ gesture: NSClickGestureRecognizer) {
        guard let view, let doc = view.document else { return }
        let point = gesture.location(in: view)
        guard let page = view.page(for: point, nearest: false) else { return }
        let local = view.convert(point, to: page)
        let box = page.bounds(for: .mediaBox)
        onSourceJump?(doc.index(for: page) + 1, Double(local.x - box.minX), Double(box.maxY - local.y))
    }
}

struct PDFKitView: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        state.pdf.view = view
        let click = NSClickGestureRecognizer(target: state.pdf, action: #selector(PDFController.doubleClick(_:)))
        click.numberOfClicksRequired = 2
        view.addGestureRecognizer(click)
        state.pdf.setDocument(state.pdfDocument)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        state.pdf.setDocument(state.pdfDocument)
    }
}

/// A plain PDF viewer for PDFs opened from the file tree.
struct StaticPDFView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url { nsView.document = PDFDocument(url: url) }
    }
}

struct PDFPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        PDFKitView()
            .overlay {
                if state.pdfDocument == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 34, weight: .light))
                        Text("Press ⌘S to compile")
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    Button { state.pdf.zoomOut() } label: { Image(systemName: "minus") }
                    Button { state.pdf.fitWidth() } label: { Image(systemName: "arrow.left.and.right") }
                    Button { state.pdf.zoomIn() } label: { Image(systemName: "plus") }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                .opacity(state.pdfDocument == nil ? 0 : 1)
            }
    }
}
