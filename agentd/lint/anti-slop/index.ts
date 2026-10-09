import { eslintCompatPlugin } from "@oxlint/plugins";

import { noChainedTypeAssertionsRule } from "./rules/no-chained-type-assertions.ts";
import { noModuleMockingRule } from "./rules/no-module-mocking.ts";
import { noWidenThenAssertRule } from "./rules/no-widen-then-assert.ts";

/** Subset of the anti-slop Oxlint rules that agentd enables. See PROVENANCE.md. */
const antiSlopPlugin = eslintCompatPlugin({
  meta: { name: "anti-slop" },
  rules: {
    "no-chained-type-assertions": noChainedTypeAssertionsRule,
    "no-module-mocking": noModuleMockingRule,
    "no-widen-then-assert": noWidenThenAssertRule,
  },
});

export default antiSlopPlugin;
