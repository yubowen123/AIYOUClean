import Foundation
import CleanRoomCore

func runProductFeatureChecks() throws {
    let available = ProductFeatures.availableScanKinds
    checkEqual(Set(available).count, available.count)
    checkEqual(Set(available), Set(ScanKind.allCases.filter { $0 != .cloud && $0 != .startup }))
    checkFalse(ProductFeatures.allows(.cloud))
    checkFalse(ProductFeatures.allows(.startup))
    for kind in available {
        checkTrue(ProductFeatures.allows(kind))
        checkTrue(ProductFeatures.isAvailable(kind.rawValue))
        checkFalse(ProductFeatures.title(for: kind).isEmpty)
    }
    let hidden = ["connections", "cloud", "updates", "screenCleaning", "systemPermissions", "startup", "coverageDetails"]
    checkEqual(Set(ProductFeatures.hiddenReasons.keys), Set(hidden))
    for identifier in hidden {
        checkFalse(ProductFeatures.isAvailable(identifier))
        checkTrue(ProductFeatures.hiddenReasons[identifier]?.isEmpty == false)
        checkFalse(ProductFeatures.availableFeatures.contains { $0.id == identifier })
    }
    for identifier in ["dashboard", "smartCare", "advancedCleanup", "malware", "maintenance", "monitor", "history", "browserPrivacy", "preferences", "about"] {
        checkTrue(ProductFeatures.isAvailable(identifier))
    }
    // ClamAV remains an optional dependency entry; policy must not silently remove it.
    checkTrue(ProductFeatures.isAvailable("malware"))
    checkFalse(ProductFeatures.isAvailable("unknown-feature"))
    let features = ProductFeatures.features
    checkEqual(Set(features.map(\.id)).count, features.count)
    checkEqual(ProductFeatures.availableFeatures.count + ProductFeatures.hiddenReasons.count, features.count)
    checkTrue(features.filter(\.available).allSatisfy { $0.hiddenReason == nil })
    checkTrue(features.filter { !$0.available }.allSatisfy { $0.hiddenReason?.isEmpty == false })
    checkEqual(ProductFeatures.title(for: .applications), "应用卸载")
    checkEqual(ProductFeatures.title(for: .similarImages), "相似图片候选")
    checkEqual(ProductFeatures.title(for: .spaceLens), "空间导航")
}
