/// Toolchain canary for the PC side.
///
/// Retirement trigger: the first real module replaces this, arriving with its
/// own failing test. Mirrors `app/lib/toolchain_canary.dart`.
export function answer(): number {
  return 42;
}
