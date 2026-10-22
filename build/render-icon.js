// 用 Electron 的离屏渲染把 SVG 渲染成带透明通道的 1024 PNG
const { app, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');

const SVG = process.argv[2] || path.join(__dirname, 'logo.svg');
const OUT = process.argv[3] || path.join(__dirname, 'icon-1024.png');

app.disableHardwareAcceleration();
app.whenReady().then(async () => {
  const svg = fs.readFileSync(SVG, 'utf8');
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;padding:0;width:1024px;height:1024px;background:transparent;overflow:hidden}
    svg{display:block;width:1024px;height:1024px}
  </style></head><body>${svg}</body></html>`;

  const win = new BrowserWindow({
    width: 1024, height: 1024,
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    webPreferences: { offscreen: true },
  });
  await win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));
  await new Promise((r) => setTimeout(r, 600));
  const img = await win.webContents.capturePage();
  fs.writeFileSync(OUT, img.toPNG());
  app.quit();
});
