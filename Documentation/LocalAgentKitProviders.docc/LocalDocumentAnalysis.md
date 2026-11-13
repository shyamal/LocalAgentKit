# Extract document structure

Recognize document text, paragraphs and tables from an encoded image.

## Analyze a document image

Choose the document-recognition initializer to use the native document recognizer.

```swift
import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders

func extractDocument(_ data: Data) async throws -> VisionResult {
    let options = try AppleVisionProvider.DocumentRecognitionConfiguration(
        languages: ["en-US"], maximumCells: 1024, maximumCharacters: 40_000)
    let provider: any VisionProvider = try AppleVisionProvider(documentRecognition: options)
    return try await provider.analyze(image: ImageInput(data: data))
}
```

Each document observation contains the native transcript, optional title,
paragraph transcripts, confidence, region bounds and recognized tables. The
result's text property joins document transcripts with newlines. When a host
constructs a result containing both OCR regions and documents, OCR text precedes
the document transcripts.

A table retains its row and column counts. Each cell has text, a bounding box and
inclusive row and column spans. Identical native appearances of a merged cell
are retained once. Cell arrays can be sparse; the adapter preserves recognized
cells rather than filling unrecognized content.

Bounding boxes use normalized coordinates with the origin at the oriented image's
lower-left corner. Embedded orientation or a host override applies through the
same image-admission path used by OCR and classification.

## Bound the returned structure

The defaults allow eight document regions, 256 paragraphs, 32 tables, 1,024 unique
cells and 40,000 Swift characters per analysis. Limits are aggregate across the
returned documents. Character accounting includes transcripts, titles, paragraphs
and cell text, including repeated representations of the same source text and
newlines joining document transcripts. Output exceeding a limit fails as a typed
vision error.

The 16 MiB encoded-byte and 24-million-pixel image defaults also apply. Native
recognition completes before output validation; these bounds do not cap native
working memory. Cancellation discards a late result, while native work already
running may take time to return.

## Interpret native results

Native grouping and recognition can vary by image and operating-system assets.
Empty recognition is a valid empty result. Explicit language hints must be
supported by the native document request; empty hints retain native defaults.

The adapter extracts transcript, paragraph and table structure. Nested cell
content is represented by its transcript. List markers, barcodes, semantic receipt
fields and cross-page document assembly require further interpretation. This
mode reads the first image of an encoded container. PDF file ingestion remains a
separate Tools capability.
