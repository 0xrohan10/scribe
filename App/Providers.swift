import Core
import Intelligence
import Transcription

/// Registers selectable providers. Add an adapter in ScribeKit and a `register` call here.
enum Providers {
    /// Known local checkpoints, available in the picker without a network request.
    static let transcriptionModels: [String: [String]] = [
        "whisperkit": [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            WhisperKitProvider.defaultModel,
        ],
        "cohere-transcribe": [CohereTranscriptionProvider.defaultModel],
    ]

    static let transcription: ProviderRegistry<any TranscriptionProvider> = {
        var r = ProviderRegistry<any TranscriptionProvider>()
        r.register(.init(id: "speech-analyzer", displayName: "Apple SpeechAnalyzer (on-device)", isAvailable: SpeechAnalyzerProvider.isSupported)) { SpeechAnalyzerProvider(vocabulary: $0.vocabulary) }
        r.register(.init(id: "whisperkit", displayName: "Whisper (on-device)", defaultModel: WhisperKitProvider.defaultModel)) { WhisperKitProvider(config: $0) }
        r.register(.init(id: "cohere-transcribe", displayName: "Cohere Transcribe (on-device)", defaultModel: CohereTranscriptionProvider.defaultModel, isAvailable: CohereTranscriptionProvider.isSupported)) { CohereTranscriptionProvider(config: $0) }
        r.register(.init(id: "fake", displayName: "Fake (demo lines)")) { _ in FakeTranscriptionProvider() }
        // TODO: DeepgramProvider, AssemblyAIProvider, OpenAIRealtimeProvider once implemented.
        return r
    }()

    static let llm: ProviderRegistry<any LLMProvider> = {
        var r = ProviderRegistry<any LLMProvider>()
        r.register(.init(id: "anthropic", displayName: "Anthropic Claude", needsAPIKey: true, defaultModel: AnthropicProvider.defaultModel)) { AnthropicProvider(config: $0) }
        r.register(.init(id: "openai-compatible", displayName: "OpenAI (or compatible)", needsBaseURL: true, defaultModel: "gpt-4.1", defaultBaseURL: OpenAICompatibleProvider.defaultBaseURL)) { OpenAICompatibleProvider(config: $0) }
        return r
    }()

    static let webSearch: ProviderRegistry<any WebSearchTool> = {
        var r = ProviderRegistry<any WebSearchTool>()
        r.register(.init(id: "parallel", displayName: "Parallel", needsAPIKey: true, defaultBaseURL: ParallelSearchTool.defaultBaseURL)) { ParallelSearchTool(config: $0) }
        return r
    }()

    static let searchGate: ProviderRegistry<any SearchGate> = {
        var r = ProviderRegistry<any SearchGate>()
        r.register(.init(id: "jev", displayName: "TypeSafe Jev", needsAPIKey: true, defaultModel: JevSearchGate.defaultModel, defaultBaseURL: JevSearchGate.defaultBaseURL)) { JevSearchGate(config: $0) }
        return r
    }()
}
