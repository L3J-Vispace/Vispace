import CoreML
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("Usage: inspect-coreml.swift <compiled .mlmodelc path>\n".utf8)
    )
    exit(64)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let model = try MLModel(contentsOf: url)
let description = model.modelDescription

print("metadata:")
for key in description.metadata.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
    print("  \(key): \(description.metadata[key] ?? "<nil>")")
}

print("inputs:")
for key in description.inputDescriptionsByName.keys.sorted() {
    print("  \(key): \(description.inputDescriptionsByName[key]!)")
}

print("outputs:")
for key in description.outputDescriptionsByName.keys.sorted() {
    print("  \(key): \(description.outputDescriptionsByName[key]!)")
}
