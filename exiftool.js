const { run } = require('./lib');

// 读取完整 EXIF / 元数据（借助系统 exiftool）
async function exif(file, exiftoolBin) {
  const buf = await run(exiftoolBin, ['-j', '-G1', '-a', '-api', 'LargeFileSupport=1', file]);
  const arr = JSON.parse(buf);
  return arr[0] || {};
}

module.exports = { exif };
