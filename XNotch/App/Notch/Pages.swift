import XNotchKit
import SwiftUI

/// A page of the open notch: the two built-ins, or one an extension provides.
struct OpenPage: Hashable {
    let id: String

    static let media = OpenPage(id: "media")
    static let shelf = OpenPage(id: "shelf")

    static func extensionPage(_ extensionID: ExtensionID, _ pageID: String) -> OpenPage {
        OpenPage(id: "ext:\(extensionID)/\(pageID)")
    }
}

/// How a page presents itself on its destination pill and switcher segment.
struct PageInfo: Identifiable, Equatable {
    let page: OpenPage
    let title: String
    let symbol: String
    let badge: Int

    var id: String { page.id }
}

/// The user's order of the pages, kept as `OpenPage` ids.
enum PageOrder {
    /// `pages` in the saved order. Ones it doesn't name keep their usual
    /// order after the ones it does.
    static func sorted(_ pages: [PageInfo], by order: [String]) -> [PageInfo] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return pages.enumerated()
            .sorted { (rank[$0.element.id] ?? order.count + $0.offset, $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset, $1.offset) }
            .map(\.element)
    }

    /// The saved order after moving `page` to `index` among `shown`. A page
    /// saved but not shown right now (Music while nothing plays) stays just
    /// before the shown page it preceded.
    static func moving(_ page: OpenPage, to index: Int, among shown: [PageInfo], in order: [String]) -> [String] {
        var ids = shown.map(\.id)
        guard let from = ids.firstIndex(of: page.id) else { return order }
        ids.remove(at: from)
        ids.insert(page.id, at: min(max(0, index), ids.count))
        for (position, id) in order.enumerated() where !ids.contains(id) {
            let follower = order[(position + 1)...].first { shown.map(\.id).contains($0) }
            ids.insert(id, at: follower.flatMap { ids.firstIndex(of: $0) } ?? ids.count)
        }
        return ids
    }
}

/// An extension's alert, with where a click on it leads.
struct ExtensionAlert: Hashable {
    let alert: NotchAlert
    let extensionID: ExtensionID

    var page: OpenPage? { alert.page.map { .extensionPage(extensionID, $0) } }
}

/// An active extension page with what's needed to lay it out and draw it.
struct ExtensionPage: Identifiable {
    let page: OpenPage
    let extensionID: ExtensionID
    let descriptor: NotchPageDescriptor
    let provider: NotchPageProviding

    var id: String { page.id }
}
