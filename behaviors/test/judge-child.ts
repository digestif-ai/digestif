// Reads the sessions under a projects directory and prints what came of it as one JSON line:
//   judge-child.ts <projects> <root> <home>
import { sessionFiles } from "../src/sessions.ts";

const [projects, root, home] = process.argv.slice(2) as [string, string, string];
const skipped: [string, string][] = [];
const unreadable: [string, string][] = [];
const files = await sessionFiles(projects, root, 0, home, undefined, {
  tempRoots: [],
  onSkipped: (d, why) => void skipped.push([d, why]),
  onUnreadableJudgement: (_d, folder, why) => void unreadable.push([folder, why]),
});
console.log(JSON.stringify({ files, skipped, unreadable }));
