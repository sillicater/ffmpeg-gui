const { run, runJSON, exists, mkdirp } = require('./lib');
const path = require('path');
const crypto = require('crypto');
const fs = require('fs');

function hashPath(p) {
  return crypto.createHash('md5').update(p).digest('hex').slice(0, 12);
}

const IMAGE_EXTS = new Set(['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'tiff', 'tif',
  'heic', 'heif', 'avif', 'ico', 'tga', 'dds']);
const AUDIO_EXTS = new Set(['mp3', 'wav', 'flac', 'aac', 'm4a', 'm4b', 'ogg', 'oga',
  'opus', 'alac', 'aiff', 'aif', 'wma', 'ape', 'dsf', 'dff', 'mka', 'caf', 'amr']);
function isImageFile(p) {
  return IMAGE_EXTS.has(path.extname(p).slice(1).toLowerCase());
}
function mediaKind(p, meta) {
  const ext = path.extname(p).slice(1).toLowerCase();
  if (IMAGE_EXTS.has(ext)) return 'image';
  if (AUDIO_EXTS.has(ext)) return 'audio';
  if (meta.video) return 'video';
  if (meta.audio.length) return 'audio';
  return 'other';
}

// ffprobe 输出 → 规整的媒体信息
function parseProbe(d) {
  const f = d.format || {};
  const video = (d.streams || []).find((s) => s.codec_type === 'video');
  const audio = (d.streams || []).filter((s) => s.codec_type === 'audio');
  const subs = (d.streams || []).filter((s) => s.codec_type === 'subtitle');

  // 杜比视界 / HDR 判定
  let dv = null;
  if (video) {
    for (const sd of video.side_data_list || []) {
      if (sd.side_data_type === 'DOVI configuration record') {
        dv = { profile: sd.dv_profile, level: sd.dv_level, signal: sd.dv_bl_signal_compatibility_id };
      }
    }
  }
  const transfer = video ? video.color_transfer : '';
  const primaries = video ? video.color_primaries : '';
  const isHDR = transfer === 'smpte2084' || transfer === 'arib-std-b67' || dv !== null;
  const isDV = dv !== null;

  let maxCLL = null, maxFALL = null;
  if (video) {
    for (const sd of video.side_data_list || []) {
      if (sd.side_data_type === 'Content light level metadata') {
        maxCLL = sd.max_content; maxFALL = sd.max_average;
      }
    }
  }

  const chapters = (d.chapters || []).map((c) => ({
    title: (c.tags && (c.tags.title || c.tags.TITLE)) || `章节 ${c.id + 1}`,
    start: Number(c.start_time) || 0,
  }));

  return {
    duration: Number(f.duration) || 0,
    bitrate: Number(f.bit_rate) || 0,
    size: Number(f.size) || 0,
    format: f.format_name || '',
    video: video ? {
      codec: video.codec_name, profile: video.profile || '',
      width: video.width, height: video.height,
      fps: evalFps(video.r_frame_rate || video.avg_frame_rate),
      pixFmt: video.pix_fmt, bitrate: Number(video.bit_rate) || 0,
      colorSpace: video.color_space || '', transfer, primaries,
      isHDR, isDV,
      dvProfile: dv ? dv.profile : null,
      dvLevel: dv ? dv.level : null,
      maxCLL, maxFALL,
      masterDisplay: video.side_data_list
        ? video.side_data_list.find((s) => s.side_data_type === 'Mastering display metadata') || null
        : null,
    } : null,
    audio: audio.map((a) => ({
      index: a.index, codec: a.codec_name, profile: a.profile || '',
      channels: a.channels || 0, layout: a.channel_layout || '',
      sampleRate: a.sample_rate || 0, bitrate: Number(a.bit_rate) || 0,
      language: (a.tags && (a.tags.language || a.tags.LANGUAGE)) || '',
      title: (a.tags && (a.tags.title || a.tags.TITLE)) || '',
      atmos: /Atmos/i.test(a.profile || '') || /JOC/i.test((a.tags && a.tags.title) || ''),
    })),
    subtitles: subs.map((s) => ({
      index: s.index, codec: s.codec_name,
      language: (s.tags && (s.tags.language || s.tags.LANGUAGE)) || '',
      title: (s.tags && (s.tags.title || s.tags.TITLE)) || '',
    })),
    chapters,
  };
}

function evalFps(s) {
  if (!s || !s.includes('/')) return 0;
  const [a, b] = s.split('/').map(Number);
  return b ? a / b : 0;
}

// 解析文件信息（ffprobe 同步）+ 可选封面 + 可选抽取字幕
// opts.cover / opts.subtitles 默认 true；打开播放器时不需要，可跳过省 CPU
async function probe(file, ffprobe, ffmpeg, workDir, opts = {}) {
  const wantCover = opts.cover !== false;
  const wantSubs = opts.subtitles !== false;
  const base = path.join(workDir, hashPath(file));
  mkdirp(base);

  const raw = await runJSON(ffprobe, [
    '-v', 'error', '-show_format', '-show_streams', '-show_chapters',
    '-show_entries', 'stream=index,codec_type,codec_name,profile,width,height,pix_fmt,color_space,color_transfer,color_primaries,r_frame_rate,avg_frame_rate,bit_rate,channels,channel_layout,sample_rate,side_data_list:stream_tags=language,title:format=duration,bit_rate,size,format_name:chapter=start_time:chapter_tags=title',
    '-of', 'json', file,
  ]);
  const meta = parseProbe(raw);
  const image = isImageFile(file);
  meta.kind = mediaKind(file, meta);

  // 分块 HEIC（iPhone 照片）：ffprobe 只能看到单个 tile，真实尺寸从 ImageIO 取
  if (image && meta.video) {
    try {
      const out = await run('/usr/bin/sips', ['-g', 'pixelWidth', '-g', 'pixelHeight',
        '-g', 'bitsPerSample', '-g', 'profile', file]);
      const w = Number((out.match(/pixelWidth:\s*(\d+)/) || [])[1]);
      const h = Number((out.match(/pixelHeight:\s*(\d+)/) || [])[1]);
      if (w > 0 && h > 0) { meta.video.width = w; meta.video.height = h; }
      meta.image = {
        bitDepth: Number((out.match(/bitsPerSample:\s*(\d+)/) || [])[1]) || null,
        profile: (out.match(/profile:\s*(.+)/) || [])[1] || '',
      };
    } catch {}
  }

  // 封面（HDR 源做色调映射再取帧）
  let cover = null;
  if (wantCover && meta.video) {
    const coverPath = path.join(base, 'cover.png'); // PNG 编码对全范围/有限范围 YUV 都兼容
    if (image) {
      // 图片交给 ImageIO 解码（sips），分块 HEIC 也能得到完整画面
      try {
        await run('/usr/bin/sips', ['-Z', '480', '-s', 'format', 'png', file, '--out', coverPath]);
        if (exists(coverPath)) cover = coverPath;
      } catch {}
    } else {
      // 单帧图片（jpg/png/heic 等）不能做 seek，否则会取不到帧
      const seek = meta.duration > 1 ? Math.max(0, Math.min(60, meta.duration * 0.05)) : 0;
      const vf = meta.video.isHDR
        ? `format=p010le,hwupload,scale_vt=w=480:h=-2:color_matrix=bt709:color_primaries=bt709:color_transfer=bt709,hwdownload,format=p010le,format=yuv420p`
        : 'scale=480:-2';
      const args = ['-hide_banner', '-loglevel', 'error', '-init_hw_device', 'videotoolbox=vt',
        '-filter_hw_device', 'vt'];
      if (seek > 0) args.push('-ss', String(seek));
      args.push('-i', file, '-map', '0:v:0', '-frames:v', '1', '-vf', vf, '-y', coverPath);
      try { await run(ffmpeg, args); if (exists(coverPath)) cover = coverPath; } catch {}
    }
  }

  // 只把「文本字幕」转成 SRT（几乎零开销）。
  // 图形字幕（PGS/VobSub）不自动 OCR——OCR 整个文件会吃满 CPU，留给用户手动触发。
  const TEXT_SUBS = ['subrip', 'srt', 'ass', 'ssa', 'webvtt', 'mov_text', 'text'];
  const subtitleFiles = [];
  if (wantSubs && meta.subtitles.length) {
    for (const s of meta.subtitles) {
      const out = path.join(base, `sub_${s.index}.srt`);
      const doneFlag = out + '.done';
      const needOCR = !TEXT_SUBS.includes(s.codec);
      subtitleFiles.push({
        index: s.index, title: s.title || s.language || `字幕${s.index}`,
        path: out, doneFlag, needOCR,
      });
      if (!needOCR) {
        const args = ['-hide_banner', '-loglevel', 'error', '-i', file, '-map', `0:${s.index}`,
          '-c:s', 'srt', '-y', out];
        run(ffmpeg, args)
          .then(() => { fs.writeFileSync(doneFlag, ''); return true; })
          .catch(() => {});
      }
    }
  }

  return { meta, cover, subtitleFiles, baseDir: base, raw };
}

module.exports = { probe, hashPath, parseProbe };
