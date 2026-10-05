import { describe, expect, it } from "vitest";
import type { ComponentChildren, VNode } from "preact";

import { Markdown } from "./Markdown";

/** Flattens a rendered tree into the VNodes and the strings it contains. */
function walk(node: ComponentChildren, out: { types: unknown[]; text: string[] }): void {
  if (node === null || node === undefined || typeof node === "boolean") return;
  if (typeof node === "string" || typeof node === "number") {
    out.text.push(String(node));
    return;
  }
  if (Array.isArray(node)) {
    for (const child of node) walk(child, out);
    return;
  }
  const vnode = node as VNode<{ children?: ComponentChildren }>;
  out.types.push(vnode.type);
  walk(vnode.props?.children, out);
}

function render(text: string): { types: unknown[]; text: string[] } {
  const out = { types: [] as unknown[], text: [] as string[] };
  walk(Markdown({ text }), out);
  return out;
}

describe("markdown rendering", () => {
  it("keeps raw HTML as text instead of markup", () => {
    const result = render('<img src=x onerror="alert(1)">\n\n뒤 문단');
    expect(result.types).not.toContain("img");
    expect(result.types).not.toContain("script");
    expect(result.text.join("")).toContain('<img src=x onerror="alert(1)">');
  });

  it("keeps inline HTML as text too", () => {
    const result = render("앞 <b>굵게</b> 뒤");
    expect(result.types).not.toContain("b");
    expect(result.text.join("")).toContain("<b>");
  });

  it("still builds real elements for markdown structure", () => {
    const result = render("# 제목\n\n- 하나\n- 둘\n\n```ts\nconst a = 1;\n```\n");
    expect(result.types).toContain("h1");
    expect(result.types).toContain("ul");
    expect(result.types).toContain("code");
    expect(result.text.join("")).toContain("const a = 1;");
  });
});
