import Core
import Intelligence
import Transcription

/// Every selectable provider. Adding one = write the adapter in ScribeKit, add one `register` line here.
enum Providers {
    static let transcription: ProviderRegistry<any TranscriptionProvider> = {
        var r = ProviderRegistry<any TranscriptionProvider>()
        r.register(.init(id: "speech-analyzer", displayName: "Apple SpeechAnalyzer (on-device)", isAvailable: SpeechAnalyzerProvider.isSupported)) { _ in SpeechAnalyzerProvider() }
        r.register(.init(id: "fake", displayName: "Fake (demo lines)")) { _ in FakeTranscriptionProvider() }
        // TODO: WhisperKitProvider, DeepgramProvider, AssemblyAIProvider, OpenAIRealtimeProvider once implemented.
        return r
    }()

    static let llm: ProviderRegistry<any LLMProvider> = {
        var r = ProviderRegistry<any LLMProvider>()
        r.register(.init(id: "anthropic", displayName: "Anthropic Claude", needsAPIKey: true, defaultModel: AnthropicProvider.defaultModel)) { AnthropicProvider(config: $0) }
        r.register(.init(id: "openai-compatible", displayName: "OpenAI-compatible", needsBaseURL: true, defaultModel: "gpt-4.1", defaultBaseURL: OpenAICompatibleProvider.defaultBaseURL)) { OpenAICompatibleProvider(config: $0) }
        return r
    }()

    static let webSearch: ProviderRegistry<any WebSearchTool> = {
        var r = ProviderRegistry<any WebSearchTool>()
        r.register(.init(id: "parallel", displayName: "Parallel", needsAPIKey: true, defaultBaseURL: ParallelSearchTool.defaultBaseURL)) { ParallelSearchTool(config: $0) }
        return r
    }()
}
