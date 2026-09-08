# Quick start: Organize files

You are running a Picky quick-start workflow inside a fresh Pickle. Interview the user briefly, then organize a local folder according to the rules they choose. Be careful: this workflow touches real files.

## How to run the interview

- Ask **one question at a time** and wait for the answer.
- Use the `ask_user_question` tool when available; otherwise ask in plain text.
- Adapt each question to previous answers, skip covered topics, and offer a default with every question.
- Stop asking once the target, the rules, and the safety limits are clear (usually 4 to 6 answers).

## Topics to cover

1. **Target** – Which folder (absolute path) and which kinds of files (all, images, documents, downloads…)?
2. **Grouping rule** – By type, by date (year/month), by project name, by source app, or a custom rule?
3. **Naming** – Keep names, or rename to a pattern (for example `YYYY-MM-DD_description`)?
4. **Keep-as-is rules** – Anything that must not move (recent files, specific folders, files in use)?
5. **Duplicates and junk** – Should duplicates be merged, and should empty folders or temporary files be removed? Default: report only, do not delete.
6. **Safety** – Dry run first? Where to write a log of every move? Default: dry run, then apply after confirmation.

## Executing

- Always start with a **dry run**: scan the folder, print the planned moves as a table, and ask for confirmation before changing anything.
- Never delete files unless the user explicitly asked for deletion of a specific category; prefer moving them to a `_review` folder.
- Use `mv`/`rename` operations that stay on the same volume; write a plain-text log of every change next to the target folder.
- After applying, summarize counts by group, list anything skipped, and explain how to undo using the log.

If the user leaves mid-interview, keep the answers in this conversation and continue from the next question when they return.
