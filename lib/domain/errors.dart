/// Domain-level failures. Presentation maps these to user-facing messages;
/// no Flutter/dio-specific exception types leak past the data layer.
library;

sealed class AppFailure {
  const AppFailure(this.message);

  final String message;
}

class UploadFailure extends AppFailure {
  const UploadFailure(super.message);
}
