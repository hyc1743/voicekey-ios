import SwiftUI

@main
struct VoiceKeyApp: App {
    @StateObject private var engine = DictationEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .onOpenURL { url in
                    guard url.scheme == SharedStore.scheme else { return }
                    if url.host == "dictate" { engine.begin(source: "url") }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            engine.handleScenePhase(active: phase == .active)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var engine: DictationEngine

    var body: some View {
        TabView {
            DictationView()
                .tabItem { Label("说话", systemImage: "mic.circle") }
            HistoryView()
                .tabItem { Label("历史", systemImage: "clock") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
            DiagnosticsView()
                .tabItem { Label("诊断", systemImage: "stethoscope") }
        }
    }
}

struct DictationView: View {
    @EnvironmentObject private var engine: DictationEngine

    private var stageText: String {
        switch engine.stage {
        case .idle: "点一下开始说话"
        case .recording: String(format: "录音中 %.1f 秒", engine.seconds)
        case .transcribing: "正在识别…"
        case .cleaning: "正在整理…"
        case .done: "完成，已复制到剪贴板"
        case .failed: "失败"
        }
    }

    private var stageColor: Color {
        switch engine.stage {
        case .idle: .secondary
        case .recording: .red
        case .transcribing, .cleaning: .orange
        case .done: .green
        case .failed: .red
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 12)

                Button {
                    engine.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(engine.stage == .recording ? Color.red.opacity(0.18) : Color.accentColor.opacity(0.12))
                            .frame(width: 168, height: 168)
                        Circle()
                            .fill(engine.stage == .recording ? Color.red : Color.accentColor)
                            .frame(width: 132, height: 132)
                        Image(systemName: engine.stage == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 46, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .overlay(
                        Circle()
                            .stroke(Color.red.opacity(Double(engine.level) * 3), lineWidth: 6)
                            .frame(width: 176, height: 176)
                    )
                }
                .buttonStyle(.plain)
                .disabled(engine.stage == .transcribing || engine.stage == .cleaning)

                Text(stageText)
                    .font(.headline)
                    .foregroundStyle(stageColor)

                if case let .failed(message) = engine.stage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if case let .done(text) = engine.stage {
                    ScrollView {
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .frame(maxHeight: 220)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button("复制") { UIPasteboard.general.string = text }
                        Button("再读一次") { engine.begin(source: "app") }
                    }
                    .buttonStyle(.bordered)
                }

                Toggle("静音 2 秒自动结束", isOn: $engine.autoStopOnSilence)
                    .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("VOXT")
            .padding(.bottom, 8)
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var engine: DictationEngine
    @State private var selection: HistoryRecord?

    var body: some View {
        NavigationStack {
            List {
                ForEach(engine.history.records) { record in
                    Button {
                        selection = record
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.text)
                                .font(.body)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                            HStack(spacing: 8) {
                                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                Text(String(format: "%.1fs", record.seconds))
                                Text(record.source == "keyboard" ? "键盘" : "App 内")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { engine.history.delete(engine.history.records[index]) }
                }
            }
            .overlay {
                if engine.history.records.isEmpty {
                    ContentUnavailableView("还没有记录", systemImage: "waveform", description: Text("说一句试试"))
                }
            }
            .navigationTitle("历史")
            .toolbar {
                if !engine.history.records.isEmpty {
                    Button("清空", role: .destructive) { engine.history.clear() }
                }
            }
            .sheet(item: $selection) { record in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            section("最终文本", record.text)
                            section("原始识别", record.raw)
                            section("模型", "ASR: \(record.asrModel)\n整理: \(record.llmModel)")
                        }
                        .padding()
                    }
                    .navigationTitle("详情")
                    .toolbar {
                        Button("复制") { UIPasteboard.general.string = record.text }
                    }
                }
            }
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
