import Foundation
import HearthModel

/// Array manipulation for the Queue / Up Next tiers (no SwiftUI dependency).
enum QueueLogic {
    /// Removes finished items, excluded ids and duplicates (keeps the first occurrence).
    static func pruned(_ items: [AnyPlayableItem], excluding excluded: Set<ItemIdentifier>, isFinished: (ItemIdentifier) -> Bool) -> [AnyPlayableItem] {
        var seen = excluded
        return items.filter { item in
            guard !isFinished(item.id) else { return false }
            return seen.insert(item.id).inserted
        }
    }

    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`.
    static func moved<Element>(_ array: [Element], from source: IndexSet, to destination: Int) -> [Element] {
        let valid = source.filter { array.indices.contains($0) }
        guard !valid.isEmpty else { return array }
        let moving = valid.map { array[$0] }
        let destination = min(max(0, destination), array.count)
        let adjustedDestination = destination - valid.filter { $0 < destination }.count
        var result = array
        for index in valid.reversed() {
            result.remove(at: index)
        }
        result.insert(contentsOf: moving, at: min(adjustedDestination, result.count))
        return result
    }

    static func removed<Element>(_ array: [Element], at offsets: IndexSet) -> [Element] {
        array.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }

    /// Splits at `index`: returns the element and everything after it (items before are dropped).
    static func take<Element>(_ array: [Element], at index: Int) -> (element: Element, remaining: [Element])? {
        guard array.indices.contains(index) else { return nil }
        return (array[index], Array(array[(index + 1)...]))
    }

    /// Inserts `item` at the front, removing an existing occurrence.
    static func insertingFront(_ item: AnyPlayableItem, into array: [AnyPlayableItem]) -> [AnyPlayableItem] {
        [item] + array.filter { $0.id != item.id }
    }

    /// Appends `item` unless it is already present.
    static func appending(_ item: AnyPlayableItem, to array: [AnyPlayableItem]) -> [AnyPlayableItem] {
        array.contains { $0.id == item.id } ? array : array + [item]
    }
}
