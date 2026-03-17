import SwiftUI
import Combine

struct ContentView: View {
    @Bindable var settings: AppSettings
    @State private var transcriptStore = TranscriptStore()
    @State private var knowledgeBase: KnowledgeBase?
    @State private var transcriptionEngine: TranscriptionEngine?
    @State private var suggestionEngine: SuggestionEngine?
    @State private var sessionStore = SessionStore()
    @State private var transcriptLogger = TranscriptLogger()
    @State private var overlayManager = OverlayManager()
    @State private var lastThemUtteranceCount = 0
    @State private var isTranscriptExpanded = false
    @State private var audioLevel: Float = 0

    var body: some View {
        VStack(spacing: 0) {
            // Compact header
            topBar

            Divider()

            // Main content: Suggestions
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("SUGGESTIONS")
                SuggestionsView(
                    suggestions: suggestionEngine?.suggestions ?? [],
                    currentSuggestion: suggestionEngine?.currentSuggestion ?? "",
                    isGenerating: suggestionEngine?.isGenerating ?? false
                )
            }

            Divider()

            // Collapsible transcript
            DisclosureGroup(isExpanded: $isTranscriptExpanded) {
                TranscriptView(
                    utterances: transcriptStore.utterances,
                    volatileYouText: transcriptStore.volatileYouText,
                    volatileThemText: transcriptStore.volatileThemText
                )
                .frame(height: 150)
            } label: {
                HStack(spacing: 6) {
                    Text("Transcript")
                        .font(.system(size: 12, weight: .medium))
                    if !transcriptStore.utterances.isEmpty {
                        Text("(\(transcriptStore.utterances.count))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if isTranscriptExpanded && !transcriptStore.utterances.isEmpty {
                        Button {
                            copyTranscript()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy transcript")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Bottom bar: live indicator + model
            ControlBar(
                isRunning: isRunning,
                audioLevel: audioLevel,
                selectedModel: settings.selectedModel,
                statusMessage: transcriptionEngine?.assetStatus,
                errorMessage: transcriptionEngine?.lastError,
                onToggle: isRunning ? stopSession : startSession
            )
        }
        .frame(minWidth: 280, maxWidth: 360, minHeight: 400)
        .background(.ultraThinMaterial)
        .task {
            if knowledgeBase == nil {
                let kb = KnowledgeBase(settings: settings)
                knowledgeBase = kb
                transcriptionEngine = TranscriptionEngine(transcriptStore: transcriptStore)
                suggestionEngine = SuggestionEngine(
                    transcriptStore: transcriptStore,
                    knowledgeBase: kb,
                    settings: settings
                )
            }
            indexKBIfNeeded()
        }
        .onChange(of: settings.kbFolderPath) {
            indexKBIfNeeded()
        }
        .onChange(of: settings.voyageApiKey) {
            indexKBIfNeeded()
        }
        .onChange(of: settings.inputDeviceID) {
            if isRunning {
                transcriptionEngine?.restartMic(inputDeviceID: settings.inputDeviceID)
            }
        }
        .onChange(of: transcriptStore.utterances.count) {
            handleNewUtterance()
        }
        .onKeyPress(.escape) {
            overlayManager.hide()
            return .handled
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            if isRunning {
                audioLevel = transcriptionEngine?.audioLevel ?? 0
            } else if audioLevel != 0 {
                audioLevel = 0
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("On The Spot")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            // KB status
            if let kb = knowledgeBase {
                if !kb.indexingProgress.isEmpty {
                    Text(kb.indexingProgress)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if kb.isIndexed {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text("\(kb.fileCount) files")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Button("KB Folder...") {
                chooseKBFolder()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.accentTeal)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var isRunning: Bool {
        transcriptionEngine?.isRunning ?? false
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .tracking(1.5)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    // MARK: - Actions

    private func startSession() {
        Task {
            await sessionStore.startSession()
            await transcriptLogger.startSession()
            await transcriptionEngine?.start(
                locale: settings.locale,
                inputDeviceID: settings.inputDeviceID
            )
        }
    }

    private func stopSession() {
        transcriptionEngine?.stop()
        Task {
            await sessionStore.endSession()
            await transcriptLogger.endSession()
        }
    }

    private func toggleOverlay() {
        let content = OverlayContent(
            suggestions: suggestionEngine?.suggestions ?? [],
            currentSuggestion: suggestionEngine?.currentSuggestion ?? "",
            isGenerating: suggestionEngine?.isGenerating ?? false,
            volatileThemText: transcriptStore.volatileThemText
        )
        overlayManager.toggle(content: content)
    }

    private func chooseKBFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose your knowledge base folder"

        if panel.runModal() == .OK, let url = panel.url {
            settings.kbFolderPath = url.path
        }
    }

    private func indexKBIfNeeded() {
        guard let url = settings.kbFolderURL, let kb = knowledgeBase else { return }
        Task {
            kb.clear()
            await kb.index(folderURL: url)
        }
    }

    private func copyTranscript() {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = transcriptStore.utterances.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker == .you ? "You" : "Them"): \(u.text)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func handleNewUtterance() {
        let utterances = transcriptStore.utterances
        guard let last = utterances.last else { return }

        // Persist to session store + transcript log
        Task {
            await sessionStore.appendRecord(SessionRecord(
                speaker: last.speaker,
                text: last.text,
                timestamp: last.timestamp,
                suggestions: nil,
                kbHits: nil
            ))
            await transcriptLogger.append(
                speaker: last.speaker == .you ? "You" : "Them",
                text: last.text,
                timestamp: last.timestamp
            )
        }

        // Trigger suggestions on THEM utterance
        if last.speaker == .them {
            suggestionEngine?.onThemUtterance(last)
        }
    }
}
