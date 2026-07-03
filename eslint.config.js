import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: [
      "**/dist",
      "**/node_modules",
      "app/**",
      "contracts/**",
      "server/coverage/**",
      ".claude/**",
      ".codegraph/**",
    ],
  },

  {
    files: ["eslint.config.js"],
    languageOptions: {
      ecmaVersion: 2022,
      globals: globals.node,
    },
    extends: [js.configs.recommended],
  },

  {
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    files: ["server/src/**/*.ts", "server/tests/**/*.ts"],
    languageOptions: {
      ecmaVersion: 2022,
      globals: globals.node,
    },
    rules: {
      "@typescript-eslint/no-unused-vars": ["warn", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
    },
  },

  {
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    files: ["verification_api/src/**/*.ts", "verification_portal/src/**/*.{ts,tsx}"],
    languageOptions: {
      ecmaVersion: 2022,
      globals: globals.node,
    },
    rules: {
      "@typescript-eslint/no-unused-vars": ["warn", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
    },
  }
);
