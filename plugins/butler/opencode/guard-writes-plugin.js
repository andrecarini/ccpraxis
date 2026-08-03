// guard-writes-plugin.js — OpenCode `tool.execute.before` hook wrapping the
// EXISTING, already-shipped hooks/guard-writes.sh unchanged.
//
// Deliberately does NOT reimplement any path-matching / write-set containment
// logic. There is exactly one write-set enforcer in this tree
// (hooks/guard-writes.sh); a second matcher here would drift from it (the
// b12/b13 shared-validator lesson). This file's whole job is to synthesize
// the two-field JSON payload guard-writes.sh already reads --
// {"tool_input":{"file_path":...},"cwd":...} -- shell out to it, and throw
// on a non-zero exit using the hook's OWN stderr as the thrown message (not
// a paraphrase), so the denial text a jailed worker sees is byte-identical
// to what a Claude-backend coordinator session sees.
const { spawnSync } = require("child_process");
const path = require("path");

module.exports = {
  name: "guard-writes",
  "tool.execute.before": async (input, output) => {
    const filePath =
      (output && output.args && (output.args.filePath || output.args.notebookPath)) ||
      (input && input.args && (input.args.filePath || input.args.notebookPath));
    if (!filePath) return; // not a write-shaped tool call; nothing to guard

    const cwd = process.cwd();
    const payload = JSON.stringify({
      tool_input: { file_path: filePath },
      cwd: cwd,
    });

    const hookPath = path.join(__dirname, "..", "hooks", "guard-writes.sh");
    const result = spawnSync("bash", [hookPath], {
      input: payload,
      encoding: "utf8",
    });

    if (result.status !== 0) {
      // Throw the hook's OWN stderr verbatim -- not a paraphrase of it -- so
      // the worker sees exactly the denial a coordinator session would.
      throw new Error(result.stderr || "guard-writes.sh denied this write");
    }
  },
};
