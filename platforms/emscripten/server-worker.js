/*
 * server-worker.js: runs freeciv-server.js (beside this file) in a Web Worker
 *
 * The page talks to it with messages:
 *   { type: "start", args, files }  writes files ({ path: bytes }) and runs
 *                                   main(args)
 *   { type: "connect", port }       a client connection (wgpipe.js)
 *   { type: "snapshot" }            saves the game in progress to /wg/,
 *                                   then answers { type: "snapshotted" }
 * and hears back:
 *   { type: "listening" }           the server takes connections
 *   { type: "saved", path, bytes }  after each save
 *   { type: "log", text }           what the server prints
 *   { type: "exit", code }          the server quit
 *
 * Of its own autosaves only the newest is kept, since each turn adds one.
 *
 * This file is licensed under Gnu General Public License version 2 or later.
 */

let accept = null;
const waiting = [];
let lastAuto = null;

self.onmessage = ({ data: m }) => {
  if (m.type === "connect") {
    if (accept) {
      accept(m.port);
    } else {
      waiting.push(m.port);
    }
  } else if (m.type === "snapshot") {
    self.Module?._wg_snapshot?.();
    postMessage({ type: "snapshotted" });
  } else if (m.type === "start") {
    start(m);
  }
};

function start({ args, files }) {
  const log = (text) => postMessage({ type: "log", text });
  const Module = {
    print: log,
    printErr: log,
    wgPipe: {
      listen(port, onConnection) {
        accept = onConnection;
        waiting.splice(0).forEach(onConnection);
        postMessage({ type: "listening", port });
      },
      unlisten() {
        accept = null;
      },
    },
    wgSaved(path) {
      const FS = Module.FS;
      const bytes = FS.readFile(path);

      if (/-auto\.sav/.test(path)) {
        if (lastAuto && lastAuto !== path) {
          try {
            FS.unlink(lastAuto);
          } catch {
            /* already gone */
          }
        }
        lastAuto = path;
      }
      postMessage({ type: "saved", path, bytes }, [bytes.buffer]);
    },
    onRuntimeInitialized() {
      const FS = Module.FS;

      FS.mkdirTree("/wg");
      for (const [path, bytes] of Object.entries(files)) {
        FS.mkdirTree(path.slice(0, path.lastIndexOf("/")) || "/");
        FS.writeFile(path, bytes);
      }
      Module.callMain(args);
    },
    onExit(code) {
      postMessage({ type: "exit", code });
    },
  };

  self.Module = Module;
  importScripts(new URL("freeciv-server.js", self.location.href).href);
}
