// A stand-in for the read behavior holding a harness: starts a long-lived child the way a later story
// will, prints its pid, and waits for the SIGTERM the node's deadline sends.
import { endOnSigterm, startChild } from "../src/read.ts";

endOnSigterm();
const child = startChild(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
console.log(child.pid);
setInterval(() => {}, 1000);
