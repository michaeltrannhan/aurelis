import WidgetKit
import SwiftUI

@main
struct AuralisWidgetBundle: WidgetBundle {
    var body: some Widget {
        AuralisMixerWidget()
        AuralisEQWidget()
    }
}
