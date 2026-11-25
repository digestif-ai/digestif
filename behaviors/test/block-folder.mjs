// Preloaded (node --import) to make reading one folder block as the system can block it: before its
// first entry, in the kernel, for good. BLOCK_FOLDER names the folder, BLOCK_FIFO a FIFO nobody writes
// to, whose opening is the block, and BLOCK_LOG a file each block appends its process's pid to.
import fs from "node:fs";
import fsp from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";

const { BLOCK_FOLDER, BLOCK_FIFO, BLOCK_LOG } = process.env;
const blocks = (path) => {
  if (path !== BLOCK_FOLDER) return false;
  fs.appendFileSync(BLOCK_LOG, `${process.pid}\n`);
  return true;
};

for (const name of ["opendir", "readdir"]) {
  const real = fsp[name];
  fsp[name] = async (path, ...rest) => {
    if (blocks(path)) await (await fsp.open(BLOCK_FIFO, "r")).close();
    return real(path, ...rest);
  };
}
const opendirSync = fs.opendirSync;
fs.opendirSync = (path, ...rest) => {
  if (blocks(path)) fs.closeSync(fs.openSync(BLOCK_FIFO, "r"));
  return opendirSync(path, ...rest);
};
syncBuiltinESMExports();
