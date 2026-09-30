/// Temporary toolchain canary.
///
/// Its only job is to prove that package resolution, the Dart compiler and the
/// test runner work in this project. It is not product code.
///
/// Retirement trigger: the first real module replaces this file, and arrives
/// with its own failing test. This file cannot be deleted (the project forbids
/// `rm`), so it is overwritten rather than removed.
int canaryAnswer() => 42;
