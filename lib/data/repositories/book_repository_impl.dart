import '../../domain/entities.dart';
import '../../domain/repositories.dart';
import '../datasources/backend_rest_api.dart';

class BookRepositoryImpl implements BookRepository {
  BookRepositoryImpl(this._api);

  final BackendRestApi _api;

  @override
  Future<List<TtsProviderInfo>> listTtsProviders() async {
    final dtos = await _api.listTtsProviders();
    return dtos.map((d) => d.toDomain()).toList();
  }

  @override
  Future<Book> uploadBook({required List<int> bytes, required String filename}) async {
    final dto = await _api.uploadBook(bytes: bytes, filename: filename);
    return dto.toDomain();
  }

}
