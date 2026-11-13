import SwiftUI

/// 书源登录: the source's loginUi form (text / password / select / button) or, for a plain login URL, the
/// in-app browser. Values are saved as the source's login info; 「登录」 runs the source's `login()`.
struct NovelSourceLoginView: View {
    let source: LegadoSource
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [LegadoClient.LoginField] = []
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var message: String?
    @State private var loggedIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(loggedIn ? "已登录 / 已保存登录信息" : "未登录").foregroundStyle(loggedIn ? .green : .secondary)
                        Spacer()
                        if loggedIn { Button("退出登录", role: .destructive) { LegadoSourceState.logout(source.bookSourceUrl); values = [:]; loggedIn = false } }
                    }
                }
                if let url = LegadoClient.loginPage(source) {
                    Section {
                        Button {
                            Task { await LegadoBrowser.open(url: url, html: nil, title: "登录 " + source.bookSourceName, sourceURL: source.bookSourceUrl); refresh() }
                        } label: { Label("在内置浏览器里登录", systemImage: "safari") }
                        .accessibilityIdentifier("login.browser")
                    } footer: { Text("在网页里登录账号后点右上角「完成」，登录状态（Cookie）会用于这个书源的请求。") }
                }
                let inputs = fields.filter { $0.type != "button" }
                if !inputs.isEmpty {
                    Section {
                        ForEach(inputs, id: \.name) { f in input(f) }
                    }
                }
                let buttons = fields.filter { $0.type == "button" }
                if !buttons.isEmpty || LegadoClient.loginJS(source) != nil {
                    Section {
                        ForEach(buttons, id: \.name) { f in
                            Button(f.name) { run(f.action ?? "") }.disabled(busy || (f.action ?? "").isEmpty)
                        }
                        if LegadoClient.loginJS(source) != nil {
                            Button("登录") { save(); run("typeof login === 'function' ? login() : ''") }.disabled(busy)
                                .accessibilityIdentifier("login.submit")
                        }
                    } footer: {
                        if busy { ProgressView() }
                    }
                }
                if let message { Section { Text(message).font(.callout) } }
            }
            .navigationTitle(source.bookSourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                if !fields.filter({ $0.type != "button" }).isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { Button("保存") { save(); message = "已保存" } }
                }
            }
            .onAppear {
                fields = LegadoClient.loginFields(source)
                values = LegadoSourceState.loginInfo(source.bookSourceUrl)
                for f in fields where values[f.name] == nil && !f.defaultValue.isEmpty && f.type == "select" { values[f.name] = f.defaultValue }
                refresh()
            }
        }
    }

    @ViewBuilder private func input(_ f: LegadoClient.LoginField) -> some View {
        let b = Binding(get: { values[f.name] ?? "" }, set: { values[f.name] = $0 })
        switch f.type {
        case "password": LabeledContent(f.name) { SecureField(f.name, text: b).multilineTextAlignment(.trailing) }
        case "select":
            Picker(f.name, selection: b) { ForEach(f.options, id: \.self) { Text($0).tag($0) } }
        default:
            LabeledContent(f.name) { TextField(f.name, text: b).textInputAutocapitalization(.never).autocorrectionDisabled().multilineTextAlignment(.trailing) }
        }
    }

    private func refresh() { loggedIn = LegadoSourceState.isLoggedIn(source.bookSourceUrl) }

    private func save() {
        if !values.isEmpty { LegadoSourceState.setLoginInfo(source.bookSourceUrl, values) }
    }

    private func run(_ action: String) {
        let s = source
        busy = true; message = nil
        Task {
            do {
                let r = try await LegadoClient.run { try LegadoClient.runLogin(s, action) }
                message = r.isEmpty ? "已执行" : r
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
            refresh()
        }
    }
}
