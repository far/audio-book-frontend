"""Minimal Result type. Expected failures are values; exceptions are for bugs.

Chosen over a dependency (e.g. `returns`) because the vocabulary needed here
is small: Ok/Err, map, and unwrap-or-raise at the API boundary.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Ok[T]:
    value: T

    def is_ok(self) -> bool:
        return True

    def map[U](self, fn: Callable[[T], U]) -> Ok[U]:
        return Ok(fn(self.value))

    def unwrap(self) -> T:
        return self.value


@dataclass(frozen=True, slots=True)
class Err[E: Exception]:
    error: E

    def is_ok(self) -> bool:
        return False

    def map[U](self, fn: Callable[[object], U]) -> Err[E]:
        return self

    def unwrap(self) -> object:
        raise self.error


type Result[T, E: Exception] = Ok[T] | Err[E]
