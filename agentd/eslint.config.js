import tseslint from "typescript-eslint";
import globals from "globals";

export default [
  {
    ignores: ["dist/**", "build/**", "scratch/**"],
  },
  {
    files: ["src/**/*.ts"],
    languageOptions: {
      parser: tseslint.parser,
      parserOptions: {
        project: "./tsconfig.json",
        tsconfigRootDir: import.meta.dirname,
        sourceType: "module",
      },
      globals: {
        ...globals.es2022,
        ...globals.node,
      },
    },
    plugins: {
      "@typescript-eslint": tseslint.plugin,
    },
    rules: {
      "@typescript-eslint/consistent-type-imports": ["warn", { prefer: "type-imports", fixStyle: "separate-type-imports" }],
      "@typescript-eslint/no-explicit-any": "warn",
      "@typescript-eslint/no-floating-promises": ["warn", { ignoreVoid: true, ignoreIIFE: true }],
      "@typescript-eslint/switch-exhaustiveness-check": "warn",
      "@typescript-eslint/ban-ts-comment": [
        "warn",
        {
          "ts-ignore": "allow-with-description",
          "ts-expect-error": "allow-with-description",
          "ts-nocheck": true,
          "ts-check": false,
          minimumDescriptionLength: 10,
        },
      ],
      "no-console": ["warn", { allow: ["warn", "error"] }],
      // Warning-first size/complexity rules (see docs/refactoring-principles.md).
      // Hard per-file ratchet enforcement lives in scripts/check-architecture-rules.js.
      "max-lines": ["warn", { max: 1500, skipBlankLines: true, skipComments: true }],
      "max-lines-per-function": ["warn", { max: 120, skipBlankLines: true, skipComments: true }],
      complexity: ["warn", { max: 18 }],
    },
  },
  {
    files: ["src/local-log.ts", "src/main.ts", "src/**/*.test.ts", "src/__tests__/**/*.ts"],
    rules: {
      "no-console": "off",
      "max-lines": "off",
      "max-lines-per-function": "off",
    },
  },
];
