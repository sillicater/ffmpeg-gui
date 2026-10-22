const path = require('path');
const fs = require('fs');

// ---------- 通用 ----------
function outputPath(input, outDir, ext) {
  const dir = outDir || path.dirname(input);
  const base = path.basename(input, path.extname(input));
  let p = path.join(dir, `${base}_转码.${ext}`);
  let i = 2;
  while (fs.existsSync(p)) p = path.join(dir, `${base}_转码${i++}.${ext}`);
  return p;
}

function outputExt(kind, s) {
  if (kind === 'image') return s.format;
  if (kind === 'audio') {
    if (s.container === 'alac') return 'm4a';
    if (s.container === 'copy') return 'mka';
    return s.container;
  }
  return s.container || 'mp4';
}

const even = (n) => { const v = Math.max(2, Math.round(Number(n) || 0)); return v % 2 ? v + 1 : v; };
const num = (v) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : 0; };
const clamp = (v, a, b) => Math.min(b, Math.max(a, Number(v) || 0));
const pick = (v, fallback) => (v === undefined || v === null || v === '' || v === 'auto' ? fallback : v);

// 把 "8M" / "4000k" / "4000000" 统一成 ffmpeg 可读的字符串
function bitrateArg(v, fallback) {
  const s = String(pick(v, fallback) || '').trim();
  return s || fallback;
}

// 解析额外参数（支持单/双引号）
function splitExtra(str) {
  const out = [];
  let cur = '', quote = null, esc = false;
  for (const ch of String(str || '')) {
    if (esc) { cur += ch; esc = false; continue; }
    if (ch === '\\') { esc = true; continue; }
    if (quote) {
      if (ch === quote) quote = null; else cur += ch;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
    } else if (/\s/.test(ch)) {
      if (cur) { out.push(cur); cur = ''; }
    } else {
      cur += ch;
    }
  }
  if (cur) out.push(cur);
  return out;
}

// ---------- 图片 ----------
const IMAGE_FORMATS = new Set(['jpg', 'jpeg', 'png', 'tiff', 'tif', 'heic', 'avif', 'bmp', 'gif']);

function buildImage(s, input, out) {
  let format = String(s.format || 'jpg').toLowerCase();
  if (format === 'jpeg') format = 'jpg';
  if (format === 'tif') format = 'tiff';
  if (!IMAGE_FORMATS.has(format)) throw new Error('不支持的图片格式：' + format);
  const args = [input, out, '--format', format,
    '--quality', String(clamp(s.quality ?? 85, 0, 100)),
    '--depth', String(s.depth || '8'),
    '--hdr', s.hdr || 'auto',
    '--resize', s.resize || 'keep',
    '--metadata', s.metadata === false ? '0' : '1'];
  if (num(s.width)) args.push('--width', String(num(s.width)));
  if (num(s.height)) args.push('--height', String(num(s.height)));
  if (num(s.percent)) args.push('--percent', String(num(s.percent)));
  return { tool: 'imgtool', args, ext: format };
}

// ---------- 音频 ----------
const AUDIO_DEFAULTS = {
  mp3: 'libmp3lame', m4a: 'aac', aac: 'aac', flac: 'flac', wav: 'pcm_s16le',
  ogg: 'libopus', alac: 'alac', copy: 'copy',
};
const LOSSLESS_AUDIO = new Set(['flac', 'wav', 'alac', 'copy']);

function buildAudio(s, input, out) {
  const container = s.container || 'mp3';
  let ext = container;
  if (container === 'alac') ext = 'm4a';
  if (container === 'copy') ext = 'mka';
  const args = ['-hide_banner', '-y', '-i', input, '-map', '0:a:0', '-vn'];
  let codec = s.codec || 'auto';
  if (codec === 'auto') codec = AUDIO_DEFAULTS[container] || 'aac';
  args.push('-c:a', codec === 'copy' ? 'copy' : codec);
  if (!LOSSLESS_AUDIO.has(container) && codec !== 'copy') {
    if (s.vbr === 'on' && codec === 'libmp3lame') {
      args.push('-q:a', '2');
    } else {
      args.push('-b:a', bitrateArg(s.bitrate, '192k'));
      if (s.vbr === 'on' && codec === 'libopus') args.push('-vbr', 'on');
    }
  }
  if (s.sampleRate && s.sampleRate !== 'auto') args.push('-ar', String(s.sampleRate));
  if (s.channels && s.channels !== 'auto') args.push('-ac', String(s.channels));
  if (s.metadata !== false) args.push('-map_metadata', '0');
  args.push(...splitExtra(s.extra));
  args.push('-progress', 'pipe:1', '-nostats', out);
  return { tool: 'ffmpeg', args, ext };
}

// ---------- 视频 ----------
const HW = ['-init_hw_device', 'videotoolbox=vt', '-filter_hw_device', 'vt'];
const SDR = { m: 'bt709', p: 'bt709', t: 'bt709' };
const TEXT_SUBS = new Set(['subrip', 'srt', 'ass', 'ssa', 'webvtt', 'mov_text', 'text']);

function scaleVT(w, h, c) {
  return `scale_vt=w=${w}:h=${h}:color_matrix=${c.m}:color_primaries=${c.p}:color_transfer=${c.t}`;
}

function sourceHDRColor(v) {
  const p = v.primaries && v.primaries !== 'unknown' ? v.primaries : 'bt2020';
  const t = v.transfer === 'arib-std-b67' ? 'arib-std-b67'
    : v.transfer === 'smpte2084' || v.isDV ? 'smpte2084' : 'smpte2084';
  return { m: 'bt2020nc', p, t };
}

function targetDims(s, v) {
  const sw = Number(v.width) || 0, sh = Number(v.height) || 0;
  if (!sw || !sh) return null;
  const mode = s.resolution || 'keep';
  let w = 0, h = 0;
  if (mode === 'custom') {
    w = num(s.width); h = num(s.height);
    if (!w && !h) return null;
    if (w && !h) h = Math.round(w * sh / sw);
    if (h && !w) w = Math.round(h * sw / sh);
  } else if (mode !== 'keep') {
    h = Number(mode) || 0;
    if (!h) return null;
    w = Math.round(h * sw / sh);
  } else {
    return null;
  }
  return { w: even(w), h: even(h) };
}

const SW_CODECS = new Set(['libx265', 'libx264', 'av1', 'vp9']);
const HW_CODECS = new Set(['hevc_vt', 'h264_vt']);

function buildVideo(s, meta, input, out) {
  const v = meta.video || {};
  const container = s.container || 'mp4';
  const vcodec = s.vcodec || 'hevc_vt';
  const copy = vcodec === 'copy';
  const isHDR = !!v.isHDR || !!v.isDV;
  const isSW = SW_CODECS.has(vcodec);
  const isHW = HW_CODECS.has(vcodec);
  const args = ['-hide_banner', '-y', '-i', input];

  if (copy) {
    args.push('-map', '0:v:0', '-c:v', 'copy');
    if (v.isDV && (container === 'mp4' || container === 'mov')) {
      args.push('-tag:v', 'dvh1', '-strict', 'unofficial');
    }
  } else {
    args.push('-map', '0:v:0');
    // H.264 只能 8bit，HDR 源必须转 SDR
    const canKeepHDR = isHDR && s.hdr !== 'sdr' && vcodec !== 'h264_vt' && vcodec !== 'libx264';
    const keepHDR = canKeepHDR;
    const d = targetDims(s, v) || {
      w: even(v.width || 1920), h: even(v.height || 1080),
    };
    const color = keepHDR ? sourceHDRColor(v) : SDR;
    let vf = '';
    let useVT = false;

    if (isHDR && keepHDR) {
      if (vcodec === 'hevc_vt') {
        useVT = true;
        vf = 'format=p010le,hwupload';
        if (targetDims(s, v)) vf += ',' + scaleVT(d.w, d.h, color);
      } else {
        vf = 'format=p010le';
        if (targetDims(s, v)) vf += `,scale=${d.w}:${d.h}:flags=lanczos`;
      }
    } else if (isHDR) {
      // HDR → SDR：用 VideoToolbox 做色调映射/BT.709 转换
      useVT = true;
      vf = `format=p010le,hwupload,${scaleVT(d.w, d.h, SDR)}`;
      if (isSW) {
        const pf = s.pixFmt && s.pixFmt !== 'auto' ? s.pixFmt : 'yuv420p';
        vf += `,hwdownload,format=p010le,format=${pf}`;
      }
    } else {
      if (targetDims(s, v)) vf = `scale=${d.w}:${d.h}:flags=lanczos`;
    }

    if (useVT) args.push(...HW);
    if (vf) args.push('-vf', vf);
    if (s.fps) args.push('-r', String(s.fps));
    if (s.pixFmt && s.pixFmt !== 'auto' && !useVT) args.push('-pix_fmt', s.pixFmt);

    // 编码器
    if (vcodec === 'hevc_vt') {
      args.push('-c:v', 'hevc_videotoolbox', '-profile:v', keepHDR ? 'main10' : 'main', '-tag:v', 'hvc1');
    } else if (vcodec === 'h264_vt') {
      args.push('-c:v', 'h264_videotoolbox');
    } else if (vcodec === 'libx265') {
      args.push('-c:v', 'libx265', '-tag:v', 'hvc1');
      if (keepHDR) args.push('-pix_fmt', s.pixFmt && s.pixFmt !== 'auto' ? s.pixFmt : 'p010le');
    } else if (vcodec === 'libx264') {
      args.push('-c:v', 'libx264');
    } else if (vcodec === 'av1') {
      args.push('-c:v', 'libsvtav1');
      if (keepHDR) args.push('-pix_fmt', s.pixFmt && s.pixFmt !== 'auto' ? s.pixFmt : 'yuv420p10le');
    } else if (vcodec === 'vp9') {
      args.push('-c:v', 'libvpx-vp9', '-row-mt', '1');
      if (keepHDR) args.push('-pix_fmt', s.pixFmt && s.pixFmt !== 'auto' ? s.pixFmt : 'yuv420p10le');
    } else {
      throw new Error('未知视频编码：' + vcodec);
    }

    // 码率 / 质量
    if (s.rateMode === 'bitrate') {
      args.push('-b:v', bitrateArg(s.bitrate, '8M'));
      if (s.maxrate) args.push('-maxrate', String(s.maxrate));
      if (s.bufsize) args.push('-bufsize', String(s.bufsize));
    } else {
      const crf = clamp(s.crf ?? 23, 0, 63);
      if (isHW) {
        // VideoToolbox 用 q:v（越小画质越好），把 CRF 粗略映射过去
        args.push('-q:v', String(clamp(Math.round(crf * 2.3 + 10), 1, 100)));
      } else if (vcodec === 'libx264' || vcodec === 'libx265') {
        args.push('-crf', String(clamp(crf, 0, 51)));
      } else if (vcodec === 'av1') {
        args.push('-crf', String(Math.round(crf * 63 / 51)));
      } else if (vcodec === 'vp9') {
        args.push('-crf', String(clamp(crf, 0, 63)), '-b:v', '0');
      }
    }

    // 预设
    if (vcodec === 'libx264' || vcodec === 'libx265') {
      if (s.preset) args.push('-preset', String(s.preset));
    } else if (vcodec === 'av1') {
      const p = String(s.preset || 'medium');
      const map = { ultrafast: 13, superfast: 12, veryfast: 11, faster: 10, fast: 9, medium: 8, slow: 6, slower: 4, veryslow: 2 };
      args.push('-preset', String(map[p] ?? 8));
    } else if (vcodec === 'vp9') {
      args.push('-deadline', 'good', '-cpu-used', '2');
    }

    // 编码档次 / 等级
    if (s.profile && s.profile !== 'auto' && !vcodec.endsWith('_vt')) {
      args.push('-profile:v', String(s.profile));
    }
    if (s.level) {
      if (vcodec === 'libx265') args.push('-level-idc', String(s.level));
      else if (vcodec === 'libx264') args.push('-level', String(s.level));
    }

    // 色彩标记（HDR 保留时明确写成 BT.2020/PQ；HDR→SDR 时写 BT.709）
    const toSDR = isHDR && !keepHDR;
    const cp = s.colorPrimaries !== 'auto' ? s.colorPrimaries : (keepHDR ? color.p : (toSDR ? 'bt709' : null));
    const ct = s.colorTrc !== 'auto' ? s.colorTrc : (keepHDR ? color.t : (toSDR ? 'bt709' : null));
    const cm = s.colorMatrix !== 'auto' ? s.colorMatrix : (keepHDR ? color.m : (toSDR ? 'bt709' : null));
    if (cp) args.push('-color_primaries', cp);
    if (ct) args.push('-color_trc', ct);
    if (cm) args.push('-colorspace', cm);
  }

  // ---- 音频 ----
  const ac = s.audioCodec || 'aac';
  if (ac === 'none') {
    args.push('-an');
  } else {
    args.push('-map', '0:a:0?');
    if (ac === 'copy') {
      args.push('-c:a', 'copy');
    } else {
      args.push('-c:a', ac === 'mp3' ? 'libmp3lame' : ac === 'opus' ? 'libopus' : ac);
      if (s.audioBitrate) args.push('-b:a', String(s.audioBitrate));
    }
    if (s.sampleRate && s.sampleRate !== 'auto') args.push('-ar', String(s.sampleRate));
    if (s.channels && s.channels !== 'auto') args.push('-ac', String(s.channels));
  }

  // ---- 字幕 ----
  if (s.subtitles) {
    if (container === 'mkv') {
      args.push('-map', '0:s?', '-c:s', 'copy');
    } else if (container === 'mp4' || container === 'mov') {
      const text = (meta.subtitles || []).filter((x) => TEXT_SUBS.has(String(x.codec || '').toLowerCase()));
      for (const t of text) args.push('-map', `0:${t.index}`);
      if (text.length) args.push('-c:s', 'mov_text');
    }
  }

  if (s.metadata !== false) args.push('-map_metadata', '0');
  if ((container === 'mp4' || container === 'mov') && s.faststart !== false) {
    args.push('-movflags', '+faststart');
  }
  args.push(...splitExtra(s.extra));
  args.push('-max_muxing_queue_size', '9999', '-progress', 'pipe:1', '-nostats', out);
  return { tool: 'ffmpeg', args, ext: container };
}

// ---------- 入口 ----------
function buildArgs(job, meta) {
  const { input, out, kind, settings } = job;
  if (!input || !out) throw new Error('缺少输入或输出路径');
  if (kind === 'image') return buildImage(settings, input, out);
  if (kind === 'audio') return buildAudio(settings, input, out);
  if (kind === 'video') return buildVideo(settings, meta || {}, input, out);
  throw new Error('未知媒体类型：' + kind);
}

module.exports = { buildArgs, outputPath, outputExt, splitExtra };
