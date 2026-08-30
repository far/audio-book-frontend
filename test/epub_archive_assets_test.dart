import 'package:aireader/data/datasources/epub_archive_assets.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) => archive.addFile(ArchiveFile(name, bytes.length, bytes)));
  return ZipEncoder().encode(archive);
}

void main() {
  const png = [0x89, 0x50, 0x4E, 0x47];

  test('reads an entry whose path matches the parser href exactly', () {
    final assets = EpubArchiveAssets.tryOpen(_zip({'images/plate.png': png}))!;

    expect(assets.read('images/plate.png'), png);
  });

  test('finds the entry when the archive nests it under an OPF root', () {
    // ImageBlock.src is relative to the OPF root, but the zip nests
    // everything under EPUB/ or OEBPS/ -- the common real-world case.
    final assets = EpubArchiveAssets.tryOpen(_zip({'OEBPS/images/plate.png': png}))!;

    expect(assets.read('images/plate.png'), png);
  });

  test('returns null when the suffix match is ambiguous', () {
    // Showing the wrong picture is worse than showing alt text.
    final assets = EpubArchiveAssets.tryOpen(
      _zip({'a/images/plate.png': png, 'b/images/plate.png': png}),
    )!;

    expect(assets.read('images/plate.png'), isNull);
  });

  test('returns null for an image the archive does not ship', () {
    final assets = EpubArchiveAssets.tryOpen(_zip({'images/plate.png': png}))!;

    expect(assets.read('images/missing.png'), isNull);
  });

  test('tryOpen returns null for bytes that are not a zip', () {
    // The backend is authoritative on whether an upload is a valid EPUB;
    // failing here means "no images", never "reject the book".
    expect(EpubArchiveAssets.tryOpen([1, 2, 3, 4]), isNull);
  });
}
