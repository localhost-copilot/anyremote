import AppKit
import SwiftUI

/// The picker's search field, filtering with every key press.
///
/// AppKit's own field rather than SwiftUI's `searchable`, which only passes
/// on committed text: with a Chinese input method, the letters typed stay
/// marked (composing) until a candidate is chosen, so nothing filtered while
/// typing. This one reports the field's text including what is being
/// composed: AppKit's own text-change callback also waits for the commit,
/// so it watches the field editor's text storage, which every composition
/// step edits. ↑ and ↓ move the selection in the list, Return opens it.
struct LiveSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var onSubmit: () -> Void
    var onMove: (MasonryPlacement.Direction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        // The clear button sends the action, not a text change.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searched(_:))
        field.sendsSearchStringImmediately = true
        field.placeholderString = prompt
        field.stringValue = text
        context.coordinator.field = field
        // The picker opens ready to type into.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.placeholderString != prompt { field.placeholderString = prompt }
        // Never overwrite a composition in progress.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !composing, field.stringValue != text { field.stringValue = text }
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: LiveSearchField
        weak var field: NSSearchField?
        /// Set once in init, removed in deinit.
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        init(_ parent: LiveSearchField) {
            self.parent = parent
            super.init()
            // The window's field editor is shared, so check it is ours. The
            // update waits until AppKit has finished the edit it reports.
            observer = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: nil
            ) { [weak self] notification in
                guard let storage = notification.object as AnyObject? else { return }
                let edited = ObjectIdentifier(storage)
                Task { @MainActor in
                    guard let self, let editor = self.field?.currentEditor() as? NSTextView,
                          let ours = editor.textStorage, ObjectIdentifier(ours) == edited else { return }
                    self.update(editor.string)
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            // The field editor's string includes marked text; stringValue doesn't.
            update((field.currentEditor() as? NSTextView)?.string ?? field.stringValue)
        }

        @objc func searched(_ sender: NSSearchField) { update(sender.stringValue) }

        private func update(_ text: String) {
            guard text != parent.text else { return }
            withAnimation(.smooth(duration: 0.25)) { parent.text = text }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Keys belong to the input method while it composes.
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.moveUp(_:)): parent.onMove(.up)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(.down)
            default: return false
            }
            return true
        }
    }
}
