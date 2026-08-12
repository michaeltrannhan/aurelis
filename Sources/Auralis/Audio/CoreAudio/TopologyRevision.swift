struct TopologyRevision: Equatable, Sendable, Hashable {
    var defaultOutputUID: String?
    var availableOutputUIDs: Set<String>
    var generation: UInt64

    init(defaultOutputUID: String?, availableOutputUIDs: Set<String>, generation: UInt64 = 0) {
        self.defaultOutputUID = defaultOutputUID
        self.availableOutputUIDs = availableOutputUIDs
        self.generation = generation
    }
}
