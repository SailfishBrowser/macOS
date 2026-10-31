import Foundation
import FoundationModels
import PDFKit
import UniformTypeIdentifiers

// Tidy Downloads with Apple's on-device model: when the rule finds a messy name and the file has text to read,
// the model names what the file is. The rule's name stands whenever the model is unavailable or fails.
@available(macOS 26, *)
enum DownloadNamer {
  // The model's name for `file`, without an extension, or nil to keep the rule's `tidied` name.
  static func name(for file: URL, tidied: String, site: String?, title: String?) async -> String? {
    let type = UTType(filenameExtension: file.pathExtension)
    let excerpt = excerpt(of: file, type: type)
    let title = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    guard excerpt != nil || title != nil else { return nil }
    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    guard model.isAvailable else { return nil }
    let prompt = [
      "Original name: \(file.lastPathComponent)",
      "Tidied name: \(tidied)",
      type?.localizedDescription.map { "Type: \($0)" },
      site.map { "Site: \($0)" },
      title.map { "PDF title: \($0)" },
      excerpt.map { "Excerpt:\n\($0)" },
    ].compactMap(\.self).joined(separator: "\n")
    let answer: String
    do {
      answer = try await LanguageModelSession(model: model, instructions: instructions)
        .respond(to: prompt, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 24)).content
    } catch {
      return nil
    }
    guard let stem = clean(answer, file: file) else { return nil }
    return DownloadName.date(in: file.lastPathComponent).map { "\(stem) \($0)" } ?? stem
  }

  private static let instructions = """
    You name downloaded files. Answer with the name only: two to six words in title case, in the language of the \
    content, naming what the file is. Give no file extension, no date and no quotes.
    """

  // A PDF's first page, or the start of a text file, cut to 1,500 characters.
  private static func excerpt(of file: URL, type: UTType?) -> String? {
    guard let type else { return nil }
    let text: String
    if type.conforms(to: .pdf) {
      guard let page = PDFDocument(url: file)?.page(at: 0)?.string else { return nil }
      text = page
    } else if type.conforms(to: .text) {
      guard let handle = try? FileHandle(forReadingFrom: file), let data = try? handle.read(upToCount: 4096) else {
        return nil
      }
      text = String(decoding: data, as: UTF8.self)
    } else {
      return nil
    }
    let excerpt = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))
    return excerpt.isEmpty ? nil : excerpt
  }

  // The answer as a file stem, or nil when it reads as a sentence or says nothing new.
  private static func clean(_ answer: String, file: URL) -> String? {
    let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.contains(where: \.isNewline), answer.firstMatch(of: #/\.\s/#) == nil,
      answer.split(whereSeparator: \.isWhitespace).count <= 8
    else { return nil }
    let quotes = CharacterSet(charactersIn: "\"“”„«»")
    let breaks = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
    var text = String(
      String.UnicodeScalarView(
        answer.unicodeScalars.compactMap { quotes.contains($0) ? nil : breaks.contains($0) ? " " : $0 }))
    text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "'‘’`")))
    let ext = "." + file.pathExtension
    if !file.pathExtension.isEmpty, text.lowercased().hasSuffix(ext.lowercased()) { text.removeLast(ext.count) }
    while text.hasSuffix(".") { text.removeLast() }
    while text.hasPrefix(".") { text.removeFirst() }
    var name = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if name.count > 60 {
      let cut = name.prefix(61)
      name = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut.prefix(60))
    }
    let original = file.deletingPathExtension().lastPathComponent
    return name.isEmpty || name.caseInsensitiveCompare(original) == .orderedSame ? nil : name
  }
}
