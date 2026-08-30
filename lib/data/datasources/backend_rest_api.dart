import 'package:dio/dio.dart';

import '../../domain/errors.dart';
import '../dto/book_dto.dart';

/// REST client for the backend. Audio has its own URL builder
/// (AudioChunkUrls) but travels the same HTTP path.
class BackendRestApi {
  BackendRestApi(this._baseUrl) : _dio = Dio(BaseOptions(baseUrl: _baseUrl));

  final String _baseUrl;
  final Dio _dio;

  String get baseUrl => _baseUrl;

  Future<List<ProviderInfoDto>> listTtsProviders() async {
    try {
      final response = await _dio.get<List<dynamic>>('/tts/providers');
      return (response.data ?? [])
          .map((p) => ProviderInfoDto.fromJson(p as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw UploadFailure(e.message ?? 'could not reach backend');
    }
  }

  /// Releases the underlying HTTP connections. Called when the provider
  /// holding this instance is disposed -- the backend address is editable
  /// at runtime, so instances really are replaced mid-session.
  void close() => _dio.close(force: true);

  Future<BookDto> uploadBook({required List<int> bytes, required String filename}) async {
    try {
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: filename),
      });
      final response = await _dio.post<Map<String, dynamic>>('/upload', data: formData);
      return BookDto.fromJson(response.data!);
    } on DioException catch (e) {
      final detail = (e.response?.data is Map) ? (e.response!.data['detail'] as String? ?? e.message) : e.message;
      throw UploadFailure(detail ?? 'upload failed');
    }
  }

}
