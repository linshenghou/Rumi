import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var pending: [URL] = []
    private var openMain: (() -> Void)?
    func connect(_ model: AppModel, openMain: @escaping () -> Void) {
        self.model = model
        self.openMain = openMain
        if !pending.isEmpty { model.add(pending); pending.removeAll() }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.add(urls) } else { pending += urls }
        application.activate(ignoringOtherApps: true)
        showMainWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
    private func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) { window.makeKeyAndOrderFront(nil) }
        else { openMain?() }
    }
    func chooseFiles() {
        showMainWindow()
        model?.chooseFiles()
    }
    func presentLinkImport() {
        showMainWindow()
        model?.presentLinkImport()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.needsQuitWait {
            model.afterStop = { sender.reply(toApplicationShouldTerminate: true) }
            model.prepareToQuit(); return .terminateLater
        }
        model.prepareToQuit(); return .terminateNow
    }
}

@main
struct PDFTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Rumi", id: "main") {
            MainWindowView(model: model, delegate: delegate)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add PDF…", action: delegate.chooseFiles).keyboardShortcut("o")
                Button("Add from Link…", action: delegate.presentLinkImport)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Export Current Paper…", action: model.exportCurrent).keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.selectedJob == nil)
            }
            CommandMenu("Papers") {
                Button("Translate Selected Papers") { model.requestTranslation() }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.eligibleSelection.isEmpty)
                Button("Cancel Selected Translations") { for job in model.selectedJobs { model.cancel(job.id) } }
                    .disabled(!model.selectedJobs.contains { $0.status.isBusy })
                Button(L10n.text(model.paused ? "Resume Queue" : "Pause Queue"), action: model.toggleQueuePause)
                    .disabled(!model.hasWork)
                Divider()
                Button("Find…") { model.findRequest = UUID() }.keyboardShortcut("f")
                    .disabled(model.selectedJob == nil)
                Divider()
                Button("Remove Selected Papers") { model.remove(model.selection) }
                    .disabled(model.selection.isEmpty || model.selectedJobs.contains { $0.status.isBusy })
            }
        }
        Settings { SettingsView(model: model) }
    }
}

private struct MainWindowView: View {
    @ObservedObject var model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ContentView(model: model).onAppear {
            delegate.connect(model, openMain: { openWindow(id: "main") })
            model.start()
        }
    }
}
