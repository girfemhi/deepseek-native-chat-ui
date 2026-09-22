import SwiftUI
import UIKit

enum ChatPortableImages {
    static let bundle = Bundle.current

    static func image(_ name: String, fallback systemName: String, template: Bool = false) -> Image {
        guard let source = UIImage(named: name, in: bundle, compatibleWith: nil) else {
            return Image(systemName: systemName)
        }
        let image = template ? source.withRenderingMode(.alwaysTemplate) : source
        return Image(uiImage: image)
    }
}
