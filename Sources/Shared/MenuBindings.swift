import Cocoa

/// Finder's action callback receives a reconstructed NSMenuItem. Its tag survives;
/// a custom representedObject does not. Snapshots stay in the extension process.
final class MenuBindings {
    struct Binding {
        let actionID: String
        let revision: String
        let context: ActionContext
    }
    private var values: [Int: Binding] = [:]
    private var nextTag = 1

    func bind(_ item: NSMenuItem, actionID: String, revision: String, context: ActionContext) {
        item.tag = nextTag
        values[nextTag] = Binding(actionID: actionID, revision: revision, context: context)
        nextTag += 1
    }

    func resolve(_ item: NSMenuItem) -> Binding? { values[item.tag] }

    func discardExpired(now: Date = Date()) {
        values = values.filter { now.timeIntervalSince($0.value.context.createdAt) < 600 }
    }
}
