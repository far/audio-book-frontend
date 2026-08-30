"""EPUB parser (plan.md Milestone 2). EPUB is structured HTML with a spine
and TOC, so chapter detection and non-text stripping come nearly free --
no layout heuristics needed, unlike PDF (out of scope, see decisions table).
"""

from __future__ import annotations

import io
import zipfile

import ebooklib
from bs4 import BeautifulSoup
from ebooklib import epub

from app.application.ports import BookParser
from app.domain.entities import Book, Chapter
from app.domain.errors import InvalidUploadError
from app.infrastructure.parsers.document_blocks import extract_blocks

# Front-matter section types to skip when picking the "first chapter"
# (plan.md: "skip cover, TOC, and front matter").
_FRONT_MATTER_TYPES = {"cover", "title-page", "toc", "copyright-page", "dedication", "epigraph"}

_MIN_CHAPTER_WORDS = 50  # below this, treat as front matter (blurb, half-title, etc.)


class EbooklibParser(BookParser):
    def __init__(self, max_uncompressed_bytes: int = 200 * 1024 * 1024) -> None:
        # Injected rather than read from config here: infrastructure may not
        # import `api.config` (dependency rule), so the composition root
        # passes it in.
        self._max_uncompressed_bytes = max_uncompressed_bytes

    def can_parse(self, filename: str, content: bytes) -> bool:
        return filename.lower().endswith(".epub")

    def parse(self, book_id: str, content: bytes) -> Book:
        self._guard_zip_bomb(content, self._max_uncompressed_bytes)

        try:
            book = epub.read_epub(io.BytesIO(content))
        except Exception as exc:
            raise InvalidUploadError(reason=f"could not read EPUB: {exc}") from exc

        title = book.get_metadata("DC", "title")
        book_title = title[0][0] if title else "Untitled"

        chapters: list[Chapter] = []
        order = 0
        for item in self._documents_in_reading_order(book):
            properties = getattr(item, "properties", None) or []
            if any(p in _FRONT_MATTER_TYPES for p in properties):
                continue

            soup = BeautifulSoup(item.get_content(), "html.parser")
            chapter_title = self._chapter_title(soup)
            text = soup.get_text(separator=" ", strip=True)
            if len(text.split()) < _MIN_CHAPTER_WORDS:
                continue  # short fragments are almost always front matter, not real chapters

            chapter_id = item.get_id()
            blocks, chunks = extract_blocks(chapter_id, item.file_name, soup)
            if not chunks:
                continue

            chapters.append(
                Chapter(
                    id=chapter_id,
                    title=chapter_title or text[:60].strip() + ("…" if len(text) > 60 else ""),
                    order=order,
                    chunks=tuple(chunks),
                    blocks=tuple(blocks),
                )
            )
            order += 1

        return Book(id=book_id, title=book_title, chapters=tuple(chapters))

    @staticmethod
    def _documents_in_reading_order(book: epub.EpubBook) -> list[epub.EpubHtml]:
        """Chapter documents in *spine* order.

        `get_items_of_type(ITEM_DOCUMENT)` yields manifest order, which is
        the order entries happen to appear in the OPF and routinely differs
        from reading order -- so chapters came out shuffled in the contents
        list. The spine is what declares reading order, so it drives
        `Chapter.order` and therefore `first_chapter()`.

        Documents missing from the spine are appended afterwards rather
        than dropped: an unreferenced document is unusual, but silently
        losing a chapter is worse than listing it last.
        """
        documents = {item.get_id(): item for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT)}

        ordered: list[epub.EpubHtml] = []
        for idref, _linear in book.spine:
            item = documents.pop(idref, None)
            if item is not None:
                ordered.append(item)
        ordered.extend(documents.values())
        return ordered

    @staticmethod
    def _chapter_title(soup: BeautifulSoup) -> str:
        heading = soup.find(["h1", "h2", "h3"])
        if heading and heading.get_text(strip=True):
            return heading.get_text(strip=True)
        return ""

    @staticmethod
    def _guard_zip_bomb(content: bytes, max_uncompressed: int) -> None:
        try:
            with zipfile.ZipFile(io.BytesIO(content)) as zf:
                total_uncompressed = sum(info.file_size for info in zf.infolist())
                for info in zf.infolist():
                    # zip-slip guard: reject any entry that would escape via path traversal.
                    if info.filename.startswith("/") or ".." in info.filename.split("/"):
                        raise InvalidUploadError(reason="unsafe path in archive")
        except zipfile.BadZipFile as exc:
            raise InvalidUploadError(reason="not a valid EPUB/zip archive") from exc

        if total_uncompressed > max_uncompressed:
            raise InvalidUploadError(reason="archive too large when decompressed")
