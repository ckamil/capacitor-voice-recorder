import Foundation

struct RecordData {

    let recordDataBase64: String?
    let mimeType: String
    let msDuration: Int
    let path: String?
    let diagnostics: [String: Any]?

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "recordDataBase64": recordDataBase64 ?? "",
            "msDuration": msDuration,
            "mimeType": mimeType,
            "path": path ?? ""
        ]
        if let diagnostics = diagnostics {
            dict["diagnostics"] = diagnostics
        }
        return dict
    }

}
