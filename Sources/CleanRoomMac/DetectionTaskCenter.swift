import Foundation
import Combine
import SwiftUI

struct DetectionActivity: Identifiable {
    let id: UUID
    let title: String
    let destination: Destination
    let canCancel: Bool
    var count = 0
    var path = ""
    var phase: String?
    var isCancelling = false
}

/// A UI operation owns this slot until its worker and result handoff end. Core
/// WorkBudget remains the lower-level resource guard; composite jobs keep this
/// slot across their per-module Core leases and across navigation.
@MainActor
final class DetectionTaskCenter: ObservableObject {
    static let shared = DetectionTaskCenter()
    @Published private(set) var active: DetectionActivity?
    @Published private(set) var lastFinished: DetectionActivity?
    private var cancellation: (() -> Void)?
    var isBusy: Bool { active != nil }
    func begin(_ title: String, destination: Destination, cancel: (() -> Void)?) -> UUID? {
        guard active == nil else { return nil }
        let id = UUID()
        cancellation = cancel
        active = DetectionActivity(id: id, title: title, destination: destination, canCancel: cancel != nil)
        return id
    }
    func update(_ id: UUID, count: Int, path: String, phase: String? = nil) {
        guard var value = active, value.id == id else { return }
        value.count = max(0, count); value.path = String(path.prefix(2048)); value.phase = phase
        active = value
    }
    func markCancelling(_ id: UUID) {
        guard var value = active, value.id == id, value.canCancel, !value.isCancelling else { return }
        value.isCancelling = true; active = value
    }
    func cancelActive() {
        guard let value = active, value.canCancel, !value.isCancelling else { return }
        markCancelling(value.id)
        cancellation?() // The slot is released only after the worker acknowledges.
    }
    func finish(_ id: UUID) {
        guard let value = active, value.id == id else { return }
        lastFinished = value; cancellation = nil; active = nil
    }
    func dismissFinished() { lastFinished = nil }
}

/// Retains controllers, not hidden SwiftUI view trees. Each controller keeps a
/// bounded page and disk result references; navigation cannot deallocate work.
@MainActor
final class FeatureStateRegistry {
    static let shared = FeatureStateRegistry()
    let tasks: DetectionTaskCenter
    private var controllers: [String: AnyObject] = [:]
    init(tasks: DetectionTaskCenter? = nil) { self.tasks = tasks ?? .shared }
    func retain<T: AnyObject>(_ key: String, create: () -> T) -> T {
        if let value = controllers[key] as? T { return value }
        precondition(controllers[key] == nil, "Feature controller key reused with another type")
        let value = create(); controllers[key] = value; return value
    }
}

@MainActor
struct DetectionActivityBar: View {
    @ObservedObject var tasks: DetectionTaskCenter
    let navigate: (Destination) -> Void
    var body: some View {
        VStack(spacing: 0) {
            if let active = tasks.active { running(active) }
            else if let ended = tasks.lastFinished { finished(ended) }
        }.frame(maxWidth: .infinity).background(Color.primary.opacity(0.035))
            .accessibilityIdentifier("task.banner")
    }
    private func progressText(_ value: DetectionActivity) -> String {
        var text = "已检查\(value.count)项"
        if let phase = value.phase { text = phase + " · " + text }
        if !value.path.isEmpty { text += " · " + value.path }
        return text
    }
    private func running(_ value: DetectionActivity) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(value.isCancelling ? "正在取消：" + value.title : value.title).font(.callout.weight(.medium))
                Text(progressText(value)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("查看任务") { navigate(value.destination) }.accessibilityIdentifier("task.return")
            if value.canCancel {
                Button(value.isCancelling ? "正在取消…" : "取消检测") { tasks.cancelActive() }
                    .disabled(value.isCancelling).accessibilityIdentifier("task.cancel")
            }
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }
    private func finished(_ value: DetectionActivity) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
            Text("任务已结束：" + value.title).font(.caption)
            Spacer()
            Button("查看结果") { navigate(value.destination) }.accessibilityIdentifier("task.result")
            Button { tasks.dismissFinished() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("收起任务提示")
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }
}
