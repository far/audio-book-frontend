import 'package:archive/archive.dart';

import '../../domain/repositories.dart';

/// Reads images straight out of the uploaded EPUB, which is a zip.
///
/// The file the user picked already contains every image, so the backend
/// neither stores nor serves them (plan.md decisions, "On images"). Entries
/// are decoded lazily and cached: a chapter revisit re-renders the same
/// images, and inflating them on every scroll frame would be wasteful.
class EpubArchiveAssets implements BookAssets {
  EpubArchiveAssets(this._archive);

  /// Decodes [bytes] as a zip, or null if it isn't a usable one -- the
  /// decoder yields an empty archive for junk input rather than throwing,
  /// so an entry-less result counts as a failure too. The backend is
  /// authoritative on whether an upload is a valid EPUB; failing here
  /// means "no images", never "reject the book".
  static EpubArchiveAssets? tryOpen(List<int> bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      return archive.files.isEmpty ? null : EpubArchiveAssets(archive);
    } catch (_) {
      return null;
    }
  }

  final Archive _archive;
  final Map<String, List<int>?> _cache = {};

  @override
  List<int>? read(String href) => _cache.putIfAbsent(href, () => _find(href)?.content as List<int>?);

  /// `ImageBlock.src` is relative to the OPF root, but the zip usually
  /// nests everything under `EPUB/` or `OEBPS/`, so an exact match fails
  /// on most real books. Rather than teach this class to read
  /// `container.xml` for the OPF path -- more EPUB knowledge on the client
  /// than the plan.md decision wants -- fall back to matching on the path
  /// suffix, and only when exactly one entry matches. An ambiguous match
  /// is treated as no match: showing the wrong picture is worse than
  /// showing alt text.
  ArchiveFile? _find(String href) {
    final files = _archive.files.where((f) => f.isFile).toList();

    final exact = files.where((f) => _normalise(f.name) == href).firstOrNull;
    if (exact != null) return exact;

    final suffixed = files.where((f) => _normalise(f.name).endsWith('/$href')).toList();
    return suffixed.length == 1 ? suffixed.single : null;
  }

  /// Archive entries can be listed with a leading `./` or `/` that the
  /// parser's normalised hrefs don't carry.
  static String _normalise(String name) =>
      name.startsWith('./') ? name.substring(2) : name.replaceFirst(RegExp('^/'), '');
}
