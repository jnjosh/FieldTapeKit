import FieldTapeKit
import Foundation

extension Baseline {
    /// The baselines built into FieldCheckKit, oldest firmware first: a copy of each `firmware/<version>/baseline.json`
    /// in the repository (ADR 0003, section 4).
    public static let builtIn: [Baseline] = {
        guard let folder = Bundle.module.url(forResource: "Baselines", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Baseline(json: Data(contentsOf: $0)) }
            .sorted { (FirmwareVersion($0.firmware) ?? FirmwareVersion("0")!) < (FirmwareVersion($1.firmware) ?? FirmwareVersion("0")!) }
    }()

    /// The baseline a run on `firmware` is compared with, as ADR 0003, section 4 says: that firmware's own, or else
    /// the one FieldTapeKit would use as its profile, the newest firmware older than it, or the oldest if it's older
    /// than all of them. `isExact` says which. Nil only if there's no baseline at all.
    public static func `for`(firmware: String, in baselines: [Baseline] = builtIn) -> (baseline: Baseline, isExact: Bool)? {
        guard let version = FirmwareVersion(firmware) else { return baselines.last.map { ($0, false) } }
        if let exact = baselines.first(where: { FirmwareVersion($0.firmware) == version }) { return (exact, true) }
        let older = baselines.last { FirmwareVersion($0.firmware).map { $0 < version } ?? false }
        return (older ?? baselines.first).map { ($0, false) }
    }
}
