// Nested shutdown owners must expire from the inside out. The npm runner owns
// lifecycle descendants, the package controller owns the runner/git command,
// and the parent-exit watchdog is the daemon's final safety deadline.
export const NPM_COMMAND_FORCE_KILL_GRACE_MS = 500;
export const PACKAGE_PROCESS_FORCE_KILL_GRACE_MS = 1_250;
export const PARENT_EXIT_FORCE_SHUTDOWN_MS = 2_000;
