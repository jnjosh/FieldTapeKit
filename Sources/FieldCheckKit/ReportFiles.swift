import Foundation

/// How FieldCheck's reports and baselines are encoded and saved.
enum ReportFiles {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys keep runs and baselines diffable in the repository.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes each file as `<name>.<extension>` in `directory`, and never overwrites one: if any of the names is
    /// taken, they all get the next free number, such as `<name>-2`.
    ///
    /// - Returns: The files' URLs, in the order given.
    static func write(_ files: [(extension: String, data: Data)], named name: String, in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        var number = 1
        while true {
            let base = number == 1 ? name : "\(name)-\(number)"
            let urls = files.map { directory.appending(path: "\(base).\($0.extension)") }
            if !urls.contains(where: { manager.fileExists(atPath: $0.path(percentEncoded: false)) }) {
                // .withoutOverwriting refuses if something took the name in between.
                for (url, file) in zip(urls, files) { try file.data.write(to: url, options: .withoutOverwriting) }
                return urls
            }
            number += 1
        }
    }
}
