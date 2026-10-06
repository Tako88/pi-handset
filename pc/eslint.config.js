// The lint gate. Type-aware rules only: everything here needs the compiler's
// types, which is why `tsc --noEmit` cannot replace it and why no other linter
// is worth adding — Biome and friends have no type-aware rules.
//
// Deliberately NOT enabled: the style half of `strictTypeChecked`
// (`no-non-null-assertion`, `no-confusing-void-expression`,
// `no-unnecessary-condition`, `return-await`). Measured 2026-10-06: they
// contribute 566 of the 1705 findings the full preset raises, and every one is a
// stylistic preference this codebase has already settled, not a defect.
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    // The config file itself is not in the TS project.
    ignores: ['node_modules/**', 'eslint.config.js'],
  },
  ...tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      // `test(...)` and friends return a promise that node:test owns; without
      // this the rule fires once per test (715 times here) and means nothing.
      '@typescript-eslint/no-floating-promises': [
        'error',
        {
          allowForKnownSafeCalls: [
            {
              from: 'package',
              package: 'node:test',
              name: ['test', 'it', 'describe', 'before', 'after', 'beforeEach', 'afterEach'],
            },
          ],
        },
      ],
      // A switch over a protocol union must name every member: the `default`
      // that used to absorb the remainder is what let a new view type fall
      // silently into the generic path.
      '@typescript-eslint/switch-exhaustiveness-check': 'error',
      // Cheap insurance for the one external API this repo compiles against.
      '@typescript-eslint/no-deprecated': 'error',
      // `restrict-template-expressions` disallows `${number}` by default, which is
      // almost every hit here; interpolating a number is not a hazard.
      '@typescript-eslint/restrict-template-expressions': ['error', { allowNumber: true }],
      // The TypeScript rule understands type-only usage; the core one does not.
      'no-unused-vars': 'off',
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
      '@typescript-eslint/consistent-type-imports': 'error',
    },
  },
  {
    // A test double implements a Promise-returning interface synchronously:
    // \`async spawnImpl() { return 4242; }\` has nothing to await, and the rule's
    // suggestion (\`return Promise.resolve(...)\`, or \`Promise.reject\` where the
    // double throws) reads worse and hides the throw.
    files: ['**/*.test.ts', 'test/**/*.ts'],
    rules: { '@typescript-eslint/require-await': 'off' },
  },
);
