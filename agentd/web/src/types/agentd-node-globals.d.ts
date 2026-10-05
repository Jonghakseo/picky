// `agentd/src/domain/async-task-contract.ts` calls `Buffer.byteLength` inside a zod
// refine that only the daemon executes. The PWA imports the protocol for its
// types and schemas, so declare that one member instead of pulling in Node types
// (which would hide accidental Node globals in browser code).
declare const Buffer: { byteLength(value: string, encoding: "utf8"): number };
