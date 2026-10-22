const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('api', {
  info: () => ipcRenderer.invoke('info'),
  pickFiles: () => ipcRenderer.invoke('pick-files'),
  pickDir: () => ipcRenderer.invoke('pick-dir'),
  probe: (file) => ipcRenderer.invoke('probe', file),
  extras: (file) => ipcRenderer.invoke('extras', file),
  exif: (file) => ipcRenderer.invoke('exif', file),
  play: (file) => ipcRenderer.invoke('play', file),
  ocr: (file, index) => ipcRenderer.invoke('ocr', file, index),
  convert: (job) => ipcRenderer.invoke('convert', job),
  cancelConvert: () => ipcRenderer.invoke('cancel-convert'),
  reveal: (p) => ipcRenderer.invoke('reveal', p),
  pathOf: (file) => webUtils.getPathForFile(file),
  onProgress: (cb) => ipcRenderer.on('progress', (_e, d) => cb(d)),
  onOcrDone: (cb) => ipcRenderer.on('ocr-done', (_e, d) => cb(d)),
  onPlayError: (cb) => ipcRenderer.on('play-error', (_e, d) => cb(d)),
});
