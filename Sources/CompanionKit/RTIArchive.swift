import Foundation

/// NSKeyedArchiver-format payloads for the Companion RTI (remote text input)
/// service. Port of pyatv's `keyed_archiver.py` and
/// `plist_payloads/rti_text_operations.py`.
///
/// The archived classes (`RTITextOperations`, `TIKeyboardOutput`, ...) are
/// private to Apple, so — like pyatv — the archives are built and read as raw
/// plists instead of going through `NSKeyedArchiver`.
///
/// Foundation exposes plist UIDs only as opaque `CFKeyedArchiverUID` objects.
/// The XML plist format spells them `<dict><key>CF$UID</key><integer>N</integer></dict>`,
/// which is what both directions below lean on.
enum RTIArchive {
    /// Payload that replaces the focused field's text with nothing
    /// (pyatv `get_rti_clear_text_payload`).
    static func clearTextPayload(sessionUUID: Data) throws -> Data {
        try encode(
            top: ["textOperations": uid(1)],
            objects: [
                "$null",
                [
                    "$class": uid(7),
                    "targetSessionUUID": uid(5),
                    "keyboardOutput": uid(2),
                    "textToAssert": uid(4),
                ],
                ["$class": uid(3)],
                ["$classname": "TIKeyboardOutput", "$classes": ["TIKeyboardOutput", "NSObject"]],
                "",
                ["NS.uuidbytes": sessionUUID, "$class": uid(6)],
                ["$classname": "NSUUID", "$classes": ["NSUUID", "NSObject"]],
                ["$classname": "RTITextOperations", "$classes": ["RTITextOperations", "NSObject"]],
            ])
    }

    /// Payload that types `text` at the cursor of the focused field
    /// (pyatv `get_rti_input_text_payload`).
    static func inputTextPayload(sessionUUID: Data, text: String) throws -> Data {
        try encode(
            top: ["textOperations": uid(1)],
            objects: [
                "$null",
                [
                    "keyboardOutput": uid(2),
                    "$class": uid(7),
                    "targetSessionUUID": uid(5),
                ],
                ["insertionText": uid(3), "$class": uid(4)],
                text,
                ["$classname": "TIKeyboardOutput", "$classes": ["TIKeyboardOutput", "NSObject"]],
                ["NS.uuidbytes": sessionUUID, "$class": uid(6)],
                ["$classname": "NSUUID", "$classes": ["NSUUID", "NSObject"]],
                ["$classname": "RTITextOperations", "$classes": ["RTITextOperations", "NSObject"]],
            ])
    }

    /// Read one or more properties from an archive by following UID
    /// references from `$top` (pyatv `read_archive_properties`). A path that
    /// does not resolve yields `nil`.
    static func readProperties(_ archive: Data, _ paths: [[String]]) throws -> [Any?] {
        // Round-trip through XML with the UID marker key renamed, so UIDs
        // come back as plain `["$uid": N]` dictionaries instead of opaque
        // objects. The marker cannot collide with archived string content:
        // XML escapes `<` inside strings.
        let parsed = try PropertyListSerialization.propertyList(from: archive, format: nil)
        let xml = try PropertyListSerialization.data(fromPropertyList: parsed, format: .xml, options: 0)
        let renamed = String(decoding: xml, as: UTF8.self)
            .replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>$uid</key>")
        let plain = try PropertyListSerialization.propertyList(from: Data(renamed.utf8), format: nil)
        guard let root = plain as? [String: Any],
              let top = root["$top"],
              let objects = root["$objects"] as? [Any]
        else { throw CompanionProtocolError.unexpectedResponse }

        return paths.map { path in
            var element: Any? = top
            for key in path {
                element = (element as? [String: Any])?[key]
                if let ref = element as? [String: Any], ref.count == 1, let index = ref["$uid"] as? Int {
                    element = objects.indices.contains(index) ? objects[index] : nil
                }
            }
            return element
        }
    }

    /// Serialize an archive whose UID references are written as `uid(n)`.
    static func encode(top: [String: Any], objects: [Any]) throws -> Data {
        let archive: [String: Any] = [
            "$version": 100000,
            "$archiver": "RTIKeyedArchiver",
            "$top": top,
            "$objects": objects,
        ]
        // Parsing the XML form turns each `CF$UID` dictionary into a real UID,
        // which the binary writer then emits as a plist UID.
        let xml = try PropertyListSerialization.data(fromPropertyList: archive, format: .xml, options: 0)
        let withUIDs = try PropertyListSerialization.propertyList(from: xml, format: nil)
        return try PropertyListSerialization.data(fromPropertyList: withUIDs, format: .binary, options: 0)
    }

    static func uid(_ index: Int) -> [String: Any] {
        ["CF$UID": index]
    }
}
