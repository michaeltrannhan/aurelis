import CoreGraphics

/// Pure geometry for the desktop output-strip transport. The strip pages by
/// one card, while `maximumLeadingIndex` keeps the last page flush to the
/// trailing edge instead of scrolling into empty space.
struct OutputDeckPagingModel: Equatable {
    static let cardWidth: CGFloat = 232
    static let cardSpacing: CGFloat = 10

    let itemCount: Int
    let viewportWidth: CGFloat

    init(itemCount: Int, viewportWidth: CGFloat) {
        self.itemCount = max(itemCount, 0)
        self.viewportWidth = viewportWidth.isFinite ? max(viewportWidth, 0) : 0
    }

    var contentWidth: CGFloat {
        guard itemCount > 0 else { return 0 }
        return CGFloat(itemCount) * Self.cardWidth
            + CGFloat(itemCount - 1) * Self.cardSpacing
    }

    var isOverflowing: Bool {
        itemCount > 1 && contentWidth > viewportWidth + 0.5
    }

    var visibleItemCount: Int {
        guard itemCount > 0 else { return 0 }
        let capacity = (viewportWidth + Self.cardSpacing)
            / (Self.cardWidth + Self.cardSpacing)
        if capacity >= CGFloat(itemCount) { return itemCount }
        return min(max(Int(capacity.rounded(.down)), 1), itemCount)
    }

    var maximumLeadingIndex: Int {
        max(itemCount - visibleItemCount, 0)
    }

    func clampedLeadingIndex(_ index: Int) -> Int {
        min(max(index, 0), maximumLeadingIndex)
    }

    func previousIndex(from index: Int) -> Int {
        max(clampedLeadingIndex(index) - 1, 0)
    }

    func nextIndex(from index: Int) -> Int {
        min(clampedLeadingIndex(index) + 1, maximumLeadingIndex)
    }

    func visibleRangeLabel(from index: Int) -> String {
        guard itemCount > 0 else { return "0 / 0" }
        let start = clampedLeadingIndex(index)
        let end = min(start + visibleItemCount, itemCount)
        return "\(start + 1)–\(end) / \(itemCount)"
    }
}

/// Resolves the one-card-at-a-time output selector used by the menu-bar popup.
/// The current system output leads the sequence, but an explicitly selected
/// physical output remains selected while the device list refreshes.
struct OutputDevicePagerModel: Equatable {
    let deviceIDs: [String]
    let selectedDeviceID: String?

    init(
        deviceIDs: [String],
        defaultDeviceID: String?,
        selectedDeviceID: String?
    ) {
        var seen: Set<String> = []
        var ordered = deviceIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        if let defaultDeviceID,
           let defaultIndex = ordered.firstIndex(of: defaultDeviceID),
           defaultIndex != 0 {
            ordered.remove(at: defaultIndex)
            ordered.insert(defaultDeviceID, at: 0)
        }
        self.deviceIDs = ordered
        self.selectedDeviceID = selectedDeviceID.flatMap { ordered.contains($0) ? $0 : nil }
            ?? ordered.first
    }

    var selectedIndex: Int {
        selectedDeviceID.flatMap { deviceIDs.firstIndex(of: $0) } ?? 0
    }

    var position: Int { deviceIDs.isEmpty ? 0 : selectedIndex + 1 }
    var count: Int { deviceIDs.count }

    var previousDeviceID: String? {
        guard selectedIndex > 0 else { return nil }
        return deviceIDs[selectedIndex - 1]
    }

    var nextDeviceID: String? {
        let nextIndex = selectedIndex + 1
        guard nextIndex < deviceIDs.count else { return nil }
        return deviceIDs[nextIndex]
    }
}
