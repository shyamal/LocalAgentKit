import Foundation
import LocalAgentKitCore
import Testing

@Suite struct StructureAwareChunkerTests {
  @Test func paragraphsStayWholeInsteadOfFillingAWordWindow() {
    let text = "Alpha beta.\n\nGamma delta.\n\nEpsilon zeta."
    let chunks = chunk(text, size: 25)
    #expect(chunks.map(\.text) == ["Alpha beta.\n\nGamma delta.", "Epsilon zeta."])
    let legacy = Chunker(configuration: .init(chunkSize: 25, overlap: 0, strategy: .wordAligned))
      .chunk(Document(title: "t", text: text))
    #expect(legacy.map(\.text) == ["Alpha beta. Gamma delta.", "Epsilon zeta."])
  }

  @Test func headingsStartSectionsEvenWhenEverythingWouldFit() {
    let text = "Intro\n\n# Budget\nFirst item\n\n## Actions\nSecond item"
    let chunks = chunk(text, size: 500)
    #expect(chunks.map(\.text) == ["Intro", "# Budget\n\nFirst item", "## Actions\n\nSecond item"])
    #expect(chunks.map { $0.metadata["sectionHeading"] } == [nil, "# Budget", "## Actions"])
    #expect(chunks.map { $0.metadata["chunkIndex"] } == ["0", "1", "2"])
  }

  @Test func adjacentHeadingsAndFinalHeadingAreNotDropped() {
    let chunks = chunk("# One\n## Two\nText\n# End", size: 100)
    #expect(chunks.map(\.text) == ["# One", "## Two\n\nText", "# End"])
  }

  @Test func fencedBlocksKeepBlankLinesAndDoNotCreateSectionsFromCode() {
    let code = "```swift\n# not a heading\n\nlet value = 1\n```"
    let chunks = chunk("# Code\n\n" + code + "\n\n# Next\nDone", size: 70)
    #expect(chunks.map(\.text) == ["# Code\n\n" + code, "# Next\n\nDone"])
    #expect(chunks[0].metadata["sectionHeading"] == "# Code")
  }

  @Test func tildeAndLongFencesRequireMatchingClosingRuns() {
    let code = "~~~~lang\n~~~\n# code\n~~~~"
    #expect(chunk(code, size: 100).map(\.text) == [code])
    let unclosed = "```\n# code\n\nStill code"
    #expect(chunk(unclosed, size: 100).map(\.text) == [unclosed])
    let contentAfterRun = "```\n``` not closing\n# code\n```"
    #expect(chunk(contentAfterRun, size: 100).map(\.text) == [contentAfterRun])
  }

  @Test func oversizedParagraphsFallBackToOverlappingWordsAndKeepSectionMetadata() {
    let words = (0..<60).map { "word\($0)" }
    let document = Document(title: "Source", text: "# Section\n" + words.joined(separator: " "))
    let chunks = Chunker(configuration: .init(chunkSize: 45, overlap: 12)).chunk(document)
    #expect(chunks.count > 2)
    #expect(chunks.allSatisfy { $0.documentID == document.id && $0.text.count <= 45 })
    #expect(chunks.allSatisfy { $0.metadata["sectionHeading"] == "# Section" })
    let windows = chunks.dropFirst()
    let covered = Set(
      windows.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) })
    #expect(covered == Set(words))
    let first = Set(chunks[1].text.split(separator: " "))
    #expect(!first.isDisjoint(with: Set(chunks[2].text.split(separator: " "))))
  }

  @Test func oversizedCodeAndWordsAlwaysMakeProgress() {
    let word = String(repeating: "界", count: 40)
    let chunks = chunk("```\n" + word + "\n```", size: 10)
    #expect(chunks.map(\.text) == ["```", word, "```"])
    #expect(chunks.count == 3)
  }

  @Test func listsAndLineBreaksRemainInsideTheirParagraph() {
    let text = "- First\n- Second\n\nParagraph\ncontinued"
    #expect(chunk(text, size: 100).map(\.text) == [text])
    #expect(chunk("One\r\n\r\nTwo\rThree", size: 100).map(\.text) == ["One\n\nTwo\nThree"])
  }

  @Test func onlyLexicalATXHeadingsAreRecognized() {
    let text = "#tag\n####### Seven\nIndented\n  # Not supported\n\n# Good\nText"
    let chunks = chunk(text, size: 200)
    #expect(chunks.count == 2)
    #expect(chunks[0].metadata["sectionHeading"] == nil)
    #expect(chunks[1].metadata["sectionHeading"] == "# Good")
    #expect(chunk("  # Indented", size: 100)[0].metadata["sectionHeading"] == nil)
  }

  @Test func exactBoundaryAndUnicodeCharacterCountsAreRespected() {
    #expect(chunk("Café\n\n界界", size: 8).map(\.text) == ["Café\n\n界界"])
    #expect(chunk("Café\n\n界界", size: 7).map(\.text) == ["Café", "界界"])
    #expect(chunk(" \n\n\t", size: 10).isEmpty)
  }

  @Test func invalidConfigurationsReturnNoChunksInEitherMode() {
    for strategy in [ChunkerConfiguration.Strategy.structureAware, .wordAligned] {
      for config in [
        ChunkerConfiguration(chunkSize: 0, overlap: 0, strategy: strategy),
        .init(chunkSize: 10, overlap: -1, strategy: strategy),
        .init(chunkSize: 10, overlap: 10, strategy: strategy),
      ] {
        #expect(Chunker(configuration: config).chunk(Document(title: "t", text: "Words")).isEmpty)
      }
    }
  }

  @Test func legacyModeKeepsItsWhitespaceAndOverlapSemantics() {
    let chunker = Chunker(configuration: .init(chunkSize: 11, overlap: 4, strategy: .wordAligned))
    let result = chunker.chunk(Document(title: "Legacy", text: "one\n\ntwo three four five"))
    #expect(result.map(\.text) == ["one two", "two three", "three four", "four five"])
    #expect(result.allSatisfy { $0.metadata["sectionHeading"] == nil })
    #expect(ChunkerConfiguration.default.strategy == .structureAware)
  }

  private func chunk(_ text: String, size: Int) -> [DocumentChunk] {
    Chunker(configuration: .init(chunkSize: size, overlap: 0))
      .chunk(Document(title: "t", text: text))
  }
}
