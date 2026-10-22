const { app, BrowserWindow, ipcMain, dialog, shell, screen } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

const { probe } = require('./probe');
const { exif } = require('./exiftool');
const { buildArgs, outputPath, outputExt } = require('./converter');
const { exists } = require('./lib');

// 只为打开文件启动时不在 Dock 留图标；需要主窗口时再显示
if (app.dock) app.dock.hide();

// —— 工具路径 ——
function findFfmpeg() {
  for (const p of ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg']) if (exists(p)) return p;
  // 开发环境保留 ffmpeg-static 兜底；安装包不再内置，减少约 44MB
  try {
    const bundled = require('ffmpeg-static').replace('app.asar', 'app.asar.unpacked');
    if (exists(bundled)) return bundled;
  } catch {}
  return null;
}
const FFMPEG = findFfmpeg();
const FFPROBE = FFMPEG ? FFMPEG.replace(/ffmpeg$/, 'ffprobe') : null;
const EXIFTOOL = exists('/opt/homebrew/bin/exiftool') ? '/opt/homebrew/bin/exiftool'
  : exists('/usr/local/bin/exiftool') ? '/usr/local/bin/exiftool' : null;
// 自带播放器（libmpv render API + 原生窗口）
function findPlayerApp() {
  const rel = 'player/build/Player.app/Contents/MacOS/Player';
  const cands = app.isPackaged
    ? [path.join(process.resourcesPath, 'player/Player.app/Contents/MacOS/Player')]
    : [path.join(__dirname, rel)];
  for (const p of cands) if (exists(p)) return p;
  return null;
}
const PLAYER = findPlayerApp();
// 图片转换工具（ImageIO：完整解码 HEIC、8/10/16 位输出）
const IMGTOOL = app.isPackaged
  ? path.join(process.resourcesPath, 'imgtool')
  : path.join(__dirname, 'build/imgtool');

let win;
const workDir = path.join(app.getPath('temp'), 'ffmpeg-gui');
const metaCache = new Map(); // file -> {meta, cover, subtitleFiles, baseDir}

// 清理一天前的临时封面/字幕/会话文件，避免目录无限增长
function cleanWorkDir() {
  try {
    const now = Date.now();
    for (const name of fs.readdirSync(workDir)) {
      const p = path.join(workDir, name);
      try {
        if (now - fs.statSync(p).mtimeMs > 24 * 3600 * 1000) {
          fs.rmSync(p, { recursive: true, force: true });
        }
      } catch {}
    }
  } catch {}
}
let activeConvert = null;
const players = new Map(); // file -> 播放器进程
const pendingOpen = [];    // 应用启动前通过 Finder 双击传入的文件
let launchedWithFile = false;
let suppressActivateUntil = 0;   // 打开文件引起的系统激活，不弹主窗口
const IMAGE_EXT = new Set(['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'tiff', 'tif',
  'heic', 'heif', 'avif', 'ico', 'tga', 'dds']);

// Finder 双击：直接开播放器，主程序随后退出，只留下查看窗口
app.on('open-file', (event, filePath) => {
  event.preventDefault();
  launchedWithFile = true;
  suppressActivateUntil = Date.now() + 1500;
  if (app.isReady()) {
    handleOpenFiles([filePath]);
  } else {
    pendingOpen.push(filePath);
  }
});

async function handleOpenFiles(files) {
  for (const f of files) {
    const r = await launchPlayer(f);
    if (r.error) showOpenError(f, r.error);
  }
  // 没有主窗口在用时，Electron 进程直接退出，和 QuickTime 一样
  if (!win) app.quit();
}

function showOpenError(file, msg) {
  dialog.showErrorBox('无法打开 ' + path.basename(file), msg);
}

let creatingWin = false;
async function createWindow() {
  if (win && !win.isDestroyed()) { win.show(); win.focus(); return; }
  if (creatingWin) return;
  creatingWin = true;
  // LSUIElement 启动时没有 Dock 图标，要主窗口时再切回普通应用
  if (app.dock) { try { await app.dock.show(); } catch {} }
  win = new BrowserWindow({
    width: 1100, height: 760, minWidth: 820, minHeight: 560,
    title: '多媒体工具',
    webPreferences: { preload: path.join(__dirname, 'preload.js') },
  });
  win.loadFile('index.html');
  creatingWin = false;
  app.focus({ steal: true });
}

app.whenReady().then(async () => {
  cleanWorkDir();
  if (pendingOpen.length) {
    await handleOpenFiles(pendingOpen.splice(0));
    return; // 已启动查看窗口，Electron 进程已退出
  }
  // 留一点时间给启动时的 open-file 事件；没有文件要打开才显示主窗口
  setTimeout(() => { if (!launchedWithFile && !win) createWindow(); }, 300);
});

app.on('activate', () => {
  // 打开文件时系统也会激活应用，这段时间内不要弹主窗口
  if (Date.now() < suppressActivateUntil) return;
  if (win && !win.isDestroyed()) { win.show(); win.focus(); }
  else createWindow();
});
app.on('window-all-closed', () => { if (activeConvert) activeConvert.kill('SIGKILL'); app.quit(); });

// —— IPC ——
ipcMain.handle('info', () => ({
  ffmpeg: FFMPEG, exiftool: !!EXIFTOOL, player: !!PLAYER, imgtool: exists(IMGTOOL),
}));

ipcMain.handle('pick-files', async () => {
  const r = await dialog.showOpenDialog(win, {
    properties: ['openFile', 'multiSelections'],
    filters: [
      { name: '媒体文件（视频 / 音频 / 图片）', extensions: [
        'mp4', 'mov', 'mkv', 'm4v', 'avi', 'webm', 'ts', 'm2ts', 'flv', 'wmv',
        'mp3', 'wav', 'flac', 'aac', 'm4a', 'ogg', 'opus', 'alac', 'aiff', 'wma', 'ape', 'mka',
        'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'tiff', 'tif', 'heic', 'heif', 'avif', 'ico',
      ] },
      { name: '所有文件', extensions: ['*'] },
    ],
  });
  return r.canceled ? [] : r.filePaths;
});
ipcMain.handle('pick-dir', async () => {
  const r = await dialog.showOpenDialog(win, { properties: ['openDirectory', 'createDirectory'] });
  return r.canceled ? null : r.filePaths[0];
});
ipcMain.handle('reveal', (_e, p) => shell.showItemInFolder(p));

// 解析文件：ffprobe 总是执行；封面/字幕只在需要时生成（extras）
async function probeFile(file, extras = false) {
  const cached = metaCache.get(file);
  if (cached && (!extras || cached.extras)) return cached;
  const info = await probe(file, FFPROBE, FFMPEG, workDir, { cover: extras, subtitles: extras });
  const entry = {
    meta: info.meta,
    cover: extras ? info.cover : (cached ? cached.cover : null),
    subtitleFiles: extras ? info.subtitleFiles : (cached ? cached.subtitleFiles : undefined),
    baseDir: info.baseDir,
    extras: extras || !!(cached && cached.extras),
  };
  metaCache.set(file, entry);
  return entry;
}

ipcMain.handle('probe', async (_e, file) => {
  try {
    const c = await probeFile(file, false);
    return { meta: c.meta, cover: c.cover, subtitleFiles: c.subtitleFiles };
  } catch (e) {
    return { error: '无法读取：' + e.message };
  }
});

// 选中文件后才生成封面和字幕，避免一次导入很多文件时集中解码
ipcMain.handle('extras', async (_e, file) => {
  try {
    const c = await probeFile(file, true);
    return { cover: c.cover, subtitleFiles: c.subtitleFiles };
  } catch (e) {
    return { error: e.message };
  }
});

// EXIF 元数据（按需读取）
ipcMain.handle('exif', async (_e, file) => {
  if (!EXIFTOOL) return { error: '未安装 exiftool，运行 brew install exiftool' };
  try { return await exif(file, EXIFTOOL); } catch (e) { return { error: e.message }; }
});

// 独立播放器安装后优先用它：双击和主程序播放按钮都走同一个窗口
function findStandalonePlayer() {
  const cands = [
    '/Applications/多媒体工具播放器.app',
    path.join(app.getPath('home'), 'Applications/多媒体工具播放器.app'),
  ];
  for (const p of cands) if (exists(p)) return p;
  return null;
}
const STANDALONE = findStandalonePlayer();

// 打开媒体：启动自带播放器（播放按钮和 Finder 双击共用）
async function launchPlayer(file) {
  if (STANDALONE) {
    try {
      const p = spawn('/usr/bin/open', ['-a', STANDALONE, file], { detached: true, stdio: 'ignore' });
      p.unref();
      return { ok: true };
    } catch (e) {
      return { error: '无法启动播放器：' + e.message };
    }
  }
  if (!PLAYER) return { error: '播放器未编译，请先运行 npm run dist 或 bash player/build.sh' };
  let cached;
  try { cached = await probeFile(file); } catch (e) { return { error: '解析失败：' + e.message }; }

  // 同时只保留一个播放器窗口
  for (const p of players.values()) { try { p.kill(); } catch {} }
  players.clear();

  // 窗口大小按屏幕计算
  const disp = screen.getPrimaryDisplay();
  const wa = disp.workAreaSize;
  let winW = Math.min(1280, Math.floor(wa.width * 0.85));
  let winH = Math.round((winW * 9) / 16);
  if (winH > wa.height * 0.85) {
    winH = Math.floor(wa.height * 0.85);
    winW = Math.round((winH * 16) / 9);
  }

  const video = (cached.meta && cached.meta.video) || {};
  const ext = path.extname(file).slice(1).toLowerCase();
  const session = {
    file,
    title: path.basename(file),
    subtitles: [],
    width: video.width || winW,
    height: video.height || winH,
    hdr: !!(video.isHDR || video.isDV),
    primaries: video.primaries || '',
    image: IMAGE_EXT.has(ext),
  };
  fs.mkdirSync(workDir, { recursive: true });
  const sessionPath = path.join(workDir, `session-${Date.now()}.json`);
  fs.writeFileSync(sessionPath, JSON.stringify(session));

  try {
    const player = spawn(PLAYER, [sessionPath], { detached: true, stdio: 'ignore' });
    players.set(file, player);
    player.on('close', () => players.delete(file));
    player.on('error', (err) => {
      players.delete(file);
      if (win && !win.isDestroyed()) win.webContents.send('play-error', { file, error: err.message });
    });
    player.unref();
  } catch (e) {
    return { error: '无法启动播放器：' + e.message };
  }
  return { ok: true };
}

ipcMain.handle('play', (_e, file) => launchPlayer(file));

// 手动 OCR 图形字幕（按需，用户点了才跑）
ipcMain.handle('ocr', async (_e, file, index) => {
  let cached;
  try { cached = await probeFile(file, true); } catch { return { error: '无此字幕轨' }; }
  const sf = (cached.subtitleFiles || []).find((s) => s.index === index);
  if (!sf) return { error: '无此字幕轨' };
  const args = ['-hide_banner', '-loglevel', 'error', '-i', file, '-map', `0:${index}`,
    '-c:s', 'srt', '-y', sf.path];
  const proc = spawn(FFMPEG, args);
  proc.on('close', (code) => {
    if (code === 0) { fs.writeFileSync(sf.doneFlag, ''); win.webContents.send('ocr-done', { file, index }); }
  });
  proc.on('error', () => {});
  return { ok: true, started: true };
});

ipcMain.handle('cancel-convert', () => { if (activeConvert) activeConvert.kill('SIGKILL'); });

function toSeconds(h, m, s) { return Number(h) * 3600 + Number(m) * 60 + Number(s); }

// 转码：视频/音频走 ffmpeg，图片走 imgtool（ImageIO）
ipcMain.handle('convert', (_e, { id, input, kind, settings, outDir }) => {
  return new Promise((resolve) => {
    const cached = metaCache.get(input);
    const meta = cached ? cached.meta : { video: {}, audio: [], subtitles: [], kind };
    let ext;
    try { ext = outputExt(kind, settings); } catch (e) { return resolve({ ok: false, error: e.message }); }
    const out = outputPath(input, outDir, ext);
    let spec;
    try { spec = buildArgs({ input, out, kind, settings }, meta); }
    catch (e) { return resolve({ ok: false, error: e.message }); }

    const bin = spec.tool === 'imgtool' ? IMGTOOL : FFMPEG;
    if (!exists(bin)) return resolve({ ok: false, error: '转换组件缺失：' + bin });

    let proc;
    try { proc = spawn(bin, spec.args); }
    catch (e) { return resolve({ ok: false, error: '无法启动转换工具：' + e.message }); }
    activeConvert = proc;
    let duration = meta.duration || 0, errTail = '';

    proc.stderr.on('data', (d) => {
      const s = d.toString();
      errTail = (errTail + s).slice(-3000);
      if (!duration) {
        const m = s.match(/Duration: (\d+):(\d+):([\d.]+)/);
        if (m) duration = toSeconds(m[1], m[2], m[3]);
      }
    });
    proc.stdout.on('data', (d) => {
      if (!duration) return;
      const ms = d.toString().match(/out_time_us=(\d+)/g);
      if (!ms) return;
      const us = Number(ms[ms.length - 1].split('=')[1]);
      if (win && !win.isDestroyed()) win.webContents.send('progress', { id, pct: Math.min(99.9, (us / 1e6 / duration) * 100) });
    });
    proc.on('close', (code, signal) => {
      activeConvert = null;
      if (code === 0) {
        if (spec.tool === 'imgtool' && win && !win.isDestroyed()) {
          win.webContents.send('progress', { id, pct: 100 });
        }
        return resolve({ ok: true, out });
      }
      try { fs.unlinkSync(out); } catch {}
      if (signal) return resolve({ ok: false, cancelled: true });
      resolve({ ok: false, error: errTail.trim().split('\n').slice(-3).join('\n') || '转换失败' });
    });
    proc.on('error', (err) => { activeConvert = null; resolve({ ok: false, error: '无法启动转换工具：' + err.message }); });
  });
});
