const { spawn } = require('child_process');
const fs = require('fs');

// 运行命令，收集输出；code 0 才算成功
function run(cmd, args, { onStdout, onStderr } = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args);
    let buf = '';
    let err = '';
    p.stdout.on('data', (d) => {
      buf += d.toString();
      if (onStdout) onStdout(d.toString());
    });
    p.stderr.on('data', (d) => {
      err = (err + d.toString()).slice(-4000);
      if (onStderr) onStderr(d.toString());
    });
    p.on('error', reject);
    p.on('close', (code) =>
      code === 0 ? resolve(buf) : reject(new Error(err.trim().split('\n').slice(-3).join('\n')))
    );
  });
}

// 运行并返回 JSON
function runJSON(cmd, args) {
  return run(cmd, args).then((buf) => JSON.parse(buf));
}

function exists(p) {
  try { fs.accessSync(p); return true; } catch { return false; }
}

function mkdirp(p) {
  fs.mkdirSync(p, { recursive: true });
}

module.exports = { run, runJSON, exists, mkdirp };
