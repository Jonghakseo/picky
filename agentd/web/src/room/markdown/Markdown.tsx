/**
 * Markdown for conversation bubbles and file previews.
 *
 * Only `marked`'s lexer runs; the tokens become VNodes here. Nothing ever
 * reaches `innerHTML`, so an agent reply cannot inject markup: a raw HTML token
 * renders as the text the model wrote.
 *
 * Block spacing and type follow the HUD bubble renderer
 * (`Picky/HUD/PickyMarkdownBlockSpacing.swift`, `PickyBubbleMarkdownContentView.swift`,
 * `Picky/HUD/Artifacts/PickyReportViewer.swift`); the values live in room.css.
 */
import { lexer } from "marked";
import type { Tokens, TokensList, Token } from "marked";
import type { ComponentChildren, JSX } from "preact";

import { classifyLink } from "../policy/links";

export interface MarkdownProps {
  text: string;
  /** Opens an http(s) link outside the app. */
  onOpenExternal?: (url: string) => void;
  /** Opens the shell's read-only preview for a path written in this room. */
  onOpenFile?: (path: string) => void;
  /** Extra class on the wrapper, for example `md md--report`. */
  class?: string;
}

export function Markdown({ text, onOpenExternal, onOpenFile, class: className }: MarkdownProps): JSX.Element {
  let tokens: TokensList | Token[];
  try {
    tokens = lexer(text);
  } catch {
    // A malformed document still has to show its text rather than disappear.
    return <div class={className ?? "md"}><p>{text}</p></div>;
  }
  const context: RenderContext = { onOpenExternal, onOpenFile };
  return <div class={className ?? "md"}>{renderBlocks(tokens, context)}</div>;
}

interface RenderContext {
  onOpenExternal?: (url: string) => void;
  onOpenFile?: (path: string) => void;
}

function renderBlocks(tokens: Token[], context: RenderContext): ComponentChildren[] {
  return tokens.map((token, index) => renderBlock(token, context, index));
}

function renderBlock(token: Token, context: RenderContext, key: number): ComponentChildren {
  switch (token.type) {
    case "space":
      return null;
    case "heading": {
      const heading = token as Tokens.Heading;
      const level = Math.min(Math.max(heading.depth, 1), 3);
      const children = renderInline(heading.tokens ?? [], context);
      if (level === 1) return <h1 key={key}>{children}</h1>;
      if (level === 2) return <h2 key={key}>{children}</h2>;
      return <h3 key={key}>{children}</h3>;
    }
    case "paragraph": {
      const paragraph = token as Tokens.Paragraph;
      return <p key={key}>{renderInline(paragraph.tokens ?? [], context)}</p>;
    }
    case "text": {
      const text = token as Tokens.Text;
      return <p key={key}>{text.tokens ? renderInline(text.tokens, context) : text.text}</p>;
    }
    case "code": {
      const code = token as Tokens.Code;
      return (
        <pre key={key}>
          <code>{code.text}</code>
        </pre>
      );
    }
    case "blockquote": {
      const quote = token as Tokens.Blockquote;
      return <blockquote key={key}>{renderBlocks(quote.tokens ?? [], context)}</blockquote>;
    }
    case "list": {
      const list = token as Tokens.List;
      const items = list.items.map((item, itemIndex) => renderListItem(item, context, itemIndex));
      if (list.ordered) {
        const start = typeof list.start === "number" ? list.start : 1;
        return (
          <ol key={key} start={start}>
            {items}
          </ol>
        );
      }
      return <ul key={key}>{items}</ul>;
    }
    case "table":
      return renderTable(token as Tokens.Table, context, key);
    case "hr":
      return <hr key={key} />;
    case "html": {
      // Raw HTML is shown as the text it is; the renderer never parses it.
      const html = token as Tokens.HTML;
      return <p key={key} class="md-raw">{html.text}</p>;
    }
    case "def":
      return null;
    default: {
      const raw = (token as { raw?: string }).raw ?? "";
      return raw.trim().length > 0 ? <p key={key}>{raw}</p> : null;
    }
  }
}

function renderListItem(item: Tokens.ListItem, context: RenderContext, key: number): ComponentChildren {
  const children = item.tokens ? renderBlocks(item.tokens, context) : item.text;
  if (item.task) {
    return (
      <li key={key} class="md-task">
        <span class={item.checked ? "md-checkbox is-checked" : "md-checkbox"} aria-hidden="true" />
        <span class="md-task-body">{children}</span>
      </li>
    );
  }
  return <li key={key}>{children}</li>;
}

function renderTable(table: Tokens.Table, context: RenderContext, key: number): ComponentChildren {
  return (
    <div key={key} class="md-table-scroll">
      <table>
        <thead>
          <tr>
            {table.header.map((cell, index) => (
              <th key={index} style={alignStyle(table.align[index])}>
                {renderInline(cell.tokens ?? [], context)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {table.rows.map((row, rowIndex) => (
            <tr key={rowIndex}>
              {row.map((cell, index) => (
                <td key={index} style={alignStyle(table.align[index])}>
                  {renderInline(cell.tokens ?? [], context)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function alignStyle(align: "center" | "left" | "right" | null | undefined): JSX.CSSProperties | undefined {
  return align ? { textAlign: align } : undefined;
}

function renderInline(tokens: Token[], context: RenderContext): ComponentChildren[] {
  return tokens.map((token, index) => renderInlineToken(token, context, index));
}

function renderInlineToken(token: Token, context: RenderContext, key: number): ComponentChildren {
  switch (token.type) {
    case "text": {
      const text = token as Tokens.Text;
      return text.tokens ? renderInline(text.tokens, context) : text.text;
    }
    case "escape":
      return (token as Tokens.Escape).text;
    case "strong": {
      const strong = token as Tokens.Strong;
      return <strong key={key}>{renderInline(strong.tokens ?? [], context)}</strong>;
    }
    case "em": {
      const em = token as Tokens.Em;
      return <em key={key}>{renderInline(em.tokens ?? [], context)}</em>;
    }
    case "del": {
      const del = token as Tokens.Del;
      return <del key={key}>{renderInline(del.tokens ?? [], context)}</del>;
    }
    case "codespan":
      return <code key={key}>{(token as Tokens.Codespan).text}</code>;
    case "br":
      return <br key={key} />;
    case "link":
      return renderLink(token as Tokens.Link, context, key);
    case "image": {
      // Remote images would reach outside the app; the alt text is what the
      // model meant to convey anyway.
      const image = token as Tokens.Image;
      return <span key={key} class="md-image">{image.text || image.href}</span>;
    }
    case "html":
      return (token as Tokens.HTML).text;
    default:
      return (token as { raw?: string }).raw ?? "";
  }
}

function renderLink(link: Tokens.Link, context: RenderContext, key: number): ComponentChildren {
  const label = link.tokens && link.tokens.length > 0 ? renderInline(link.tokens, context) : link.text || link.href;
  const target = classifyLink(link.href);
  if (target.kind === "external") {
    return (
      <a
        key={key}
        href={target.url}
        rel="noreferrer noopener"
        target="_blank"
        onClick={(event: MouseEvent) => {
          if (!context.onOpenExternal) return;
          event.preventDefault();
          context.onOpenExternal(target.url);
        }}
      >
        {label}
      </a>
    );
  }
  if (target.kind === "file" && context.onOpenFile) {
    const path = target.path;
    return (
      <button
        key={key}
        type="button"
        class="md-file-link"
        onClick={() => context.onOpenFile?.(path)}
      >
        {label}
      </button>
    );
  }
  return <span key={key}>{label}</span>;
}
