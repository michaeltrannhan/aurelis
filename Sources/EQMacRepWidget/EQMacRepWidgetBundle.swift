import WidgetKit
import SwiftUI

@main
struct EQMacRepWidgetBundle: WidgetBundle {
    var body: some Widget {
        EQMacRepMixerWidget()
        EQMacRepEQWidget()
    }
}
