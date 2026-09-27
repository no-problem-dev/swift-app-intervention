#if os(iOS)
import AppIntervention
import UIKit

/// Opens reopen URLs with `UIApplication.open`. Must be called from the foreground UI.
///
/// Opening another app's URL scheme needs no `LSApplicationQueriesSchemes` entry; that list is
/// only for `canOpenURL`.
@MainActor
public final class SystemAppReopener: AppReopener {
    public init() {}

    public func open(_ url: URL, universalLinksOnly: Bool) async -> Bool {
        let options: [UIApplication.OpenExternalURLOptionsKey: Any] = universalLinksOnly ? [.universalLinksOnly: true] : [:]
        return await UIApplication.shared.open(url, options: options)
    }
}
#endif
