// A stand-in for the read behavior holding a harness: starts a long-lived child the way a later story
// will, prints its pid, and waits for the SIGTERM the node's deadline sends. An argument is a file it
// begins reading first.
import { readFile } from "node:fs/promises";
import { endOnSigterm, startChild } from "../src/read.ts";

endOnSigterm();
if (process.argv[2] !== undefined) void readFile(process.argv[2]);
const child = startChild(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
console.log(child.pid);
setInterval(() => {}, 1000);
