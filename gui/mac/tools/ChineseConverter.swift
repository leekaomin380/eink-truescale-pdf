import Foundation

// One UTF-8 JSON batch per document; no network or extra font/runtime dependencies.
do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let strings = try JSONDecoder().decode([String].self, from: input)
    let converted = try strings.map { value -> String in
        guard let result = value.applyingTransform(StringTransform("Hans-Hant"), reverse: false) else {
            throw NSError(domain: "ChineseConverter", code: 1)
        }
        return result
    }
    FileHandle.standardOutput.write(try JSONEncoder().encode(converted))
} catch {
    FileHandle.standardError.write(Data("Traditional Chinese conversion failed.\n".utf8))
    exit(1)
}
