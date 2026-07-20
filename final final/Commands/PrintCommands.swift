//
//  PrintCommands.swift
//  final final
//
//  Print menu notification names and operation handlers.
//

import SwiftUI
import AppKit
import PDFKit

// MARK: - Notification Names

extension Notification.Name {
    /// Request to print the formatted document (reuses the PDF export pipeline)
    static let printFormatted = Notification.Name("printFormatted")
    /// Request to print the literal markdown source, unstyled
    static let printRawMarkdown = Notification.Name("printRawMarkdown")
}

// MARK: - Print Operation Handlers

/// Handles print menu operations
@MainActor
struct PrintOperations {

    /// Errors specific to turning an export/print pipeline result into a print job
    /// (as opposed to `ExportError`, which covers the Pandoc pipeline itself).
    private enum PrintError: LocalizedError {
        case pdfLoadFailed
        case printOperationFailed

        var errorDescription: String? {
            switch self {
            case .pdfLoadFailed:
                return "Could not load the rendered document for printing."
            case .printOperationFailed:
                return "Could not create a print job for this document."
            }
        }
    }

    // MARK: - Formatted Print

    /// Print the document formatted, reusing the exact same Pandoc -> xelatex pipeline
    /// (and Pandoc-availability check/alert) as "Export as PDF...", so formatted print
    /// output matches PDF export instead of going through a second renderer. Renders to
    /// a temp PDF, then hands that off to the standard macOS print panel via PDFKit.
    static func handlePrintFormatted() async {
        let dm = DocumentManager.shared
        guard let content = try? await dm.loadContentForExport(), !content.isEmpty else {
            showNoContentAlert()
            return
        }

        let projectURL = dm.projectURL

        // Same Pandoc check + "Pandoc Not Found" alert used by PDF export -- reused via
        // the shared ExportViewModel instance rather than duplicated here.
        await ExportOperations.exportViewModel.configure()
        guard ExportOperations.exportViewModel.isPandocAvailable else {
            ExportOperations.exportViewModel.showPandocNotFoundAlert()
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        // Placed immediately after the temp URL is decided (before the pipeline that
        // populates it runs) so cleanup fires on every exit path below, including
        // thrown errors and early returns -- not just the happy path.
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            _ = try await ExportOperations.exportViewModel.export(
                content: content,
                to: tempURL,
                format: .pdf,
                projectURL: projectURL
            )
        } catch {
            showPrintErrorAlert(error: error)
            return
        }

        guard let pdfDocument = PDFDocument(url: tempURL) else {
            showPrintErrorAlert(error: PrintError.pdfLoadFailed)
            return
        }

        // `printOperation(for:scalingMode:autoRotate:)` is a PDFDocument method (verified
        // against the PDFKit headers -- PDFView has no such member, only the imperative
        // printWithInfo:autoRotate:/pageScaling: methods, which don't hand back an
        // NSPrintOperation). No PDFView is needed at all for this path.
        guard let printOperation = pdfDocument.printOperation(
            for: NSPrintInfo.shared,
            scalingMode: .pageScaleDownToFit,
            autoRotate: true
        ) else {
            showPrintErrorAlert(error: PrintError.printOperationFailed)
            return
        }

        printOperation.run()
    }

    // MARK: - Raw Markdown Print

    /// Print the literal markdown source text, unstyled -- assembled via the same
    /// plain-markdown path "Export Markdown with Images"/"TextBundle" use
    /// (`exportBlocks()` + `BlockParser.assembleStandardMarkdownForExport`), rendered
    /// into a plain monospaced NSTextView with no styling, and handed to the standard
    /// macOS print panel.
    static func handlePrintRawMarkdown() async {
        let dm = DocumentManager.shared
        guard dm.projectDatabase != nil, dm.projectId != nil else {
            showNoContentAlert()
            return
        }

        let blocks: [Block]
        do {
            blocks = try await dm.exportBlocks()
        } catch {
            showPrintErrorAlert(error: error)
            return
        }

        let content = BlockParser.assembleStandardMarkdownForExport(from: blocks)
        guard !content.isEmpty else {
            showNoContentAlert()
            return
        }

        // Plain, unstyled monospaced text view. Width matches the *actual* printable
        // area of the current NSPrintInfo, not a hardcoded zero-margin US Letter guess
        // -- the imageable area is always smaller than nominal paper size (printer
        // hardware border + margins), so a fixed 612pt guess slices every line onto
        // side-by-side overflow pages on real printers and on A4-default machines. An
        // unconstrained container height plus isVerticallyResizable lets the view
        // grow to the full rendered content height so NSPrintOperation paginates it
        // vertically instead of clipping to a single page.
        let printInfo = NSPrintInfo.shared
        // `imageablePageBounds` is the printer's actual marking area (accounts for
        // hardware margins the paper-size/left-right-margin math can't see), so it's
        // used directly instead of `paperSize.width - leftMargin - rightMargin`.
        let pageWidth: CGFloat = printInfo.imageablePageBounds.width
        // Horizontal-only .fit: scales content down to the imageable width instead of
        // tiling overflow onto extra pages (NSPrintInfo's .automatic default). Only
        // horizontalPagination is touched -- verticalPagination stays .automatic --
        // so the multi-page vertical flow above is untouched; .fit is correct here
        // because horizontal pagination is a page-wide scale transform NSPrintOperation
        // applies before handing off to NSTextView's own (vertical-only) per-page
        // layout, so it composes cleanly with NSTextView's custom pagination instead
        // of conflicting with it.
        printInfo.horizontalPagination = .fit
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: 792))
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: pageWidth, height: .greatestFiniteMagnitude)
        textView.string = content
        textView.sizeToFit()

        NSPrintOperation(view: textView, printInfo: printInfo).run()
    }

    // MARK: - Alerts

    private static func showNoContentAlert() {
        let alert = NSAlert()
        alert.messageText = "No Content to Print"
        alert.informativeText = "Open a project with content before printing."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showPrintErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Print Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
