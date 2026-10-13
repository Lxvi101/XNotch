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

/// An active extension page with what's needed to lay it out and draw it.
struct ExtensionPage: Identifiable {
    let page: OpenPage
    let extensionID: ExtensionID
    let descriptor: NotchPageDescriptor
    let provider: NotchPageProviding

    var id: String { page.id }
}
