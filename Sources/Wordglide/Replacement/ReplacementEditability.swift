/// Conservative editability rules shared by selection and whole-field replacement.
/// Range writability alone is insufficient: read-only text views can expose it.
struct ReplacementEditability {
    static func allows(
        role: String,
        enabled: Bool?,
        readOnly: Bool?,
        explicitEditable: Bool?,
        valueWritable: Bool,
        selectedTextWritable: Bool,
        selectionWritable: Bool,
        advertisedEditableRoot: Bool
    ) -> Bool {
        guard enabled != false, readOnly != true, explicitEditable != false else { return false }

        let standardTextRole = role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"
        guard standardTextRole || role == "AXGroup" else { return false }

        // Some browser contenteditable groups expose neither writable AXValue nor
        // writable AXSelectedText. The caller must confirm AXEditableAncestor is
        // advertised and resolves to this exact element before supplying this flag.
        // Do not extend this fallback to atomic text fields: browsers may advertise
        // them as editing roots even when their text is read-only.
        if role == "AXGroup" { return advertisedEditableRoot && selectionWritable }

        return valueWritable || selectedTextWritable || explicitEditable == true
    }
}
