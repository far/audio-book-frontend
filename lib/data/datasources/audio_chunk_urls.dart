import '../../domain/entities.dart';

/// Data plane URL builder (ADR-1). Audio is fetched over HTTP, cacheable,
/// independent of the WS control-plane connection.
class AudioChunkUrls {
  const AudioChunkUrls(this.baseUrl);

  final String baseUrl;

  Uri chunkUri(String chunkId, TtsSelection selection) => Uri.parse('$baseUrl/tts/chunk/$chunkId').replace(
    queryParameters: {'provider': selection.provider, 'voice_id': selection.voiceId},
  );
}
