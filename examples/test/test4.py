#!/usr/bin/env python3
"""
GPT-OSS-20B 语音聊天演示（麦克风波形 + 流式对话）

功能：
  - 实时麦克风波形可视化（Web Audio API）
  - 浏览器语音识别（Web Speech API）
  - 流式调用本地 GPT-OSS-20B vLLM 服务器
  - SSE 推送回浏览器，逐 token 显示

运行方式（需激活 env_vllm2 环境）：
  python3 examples/test/test4.py

访问地址：
  本机: http://localhost:5000
  局域网: http://<IP>:5000

依赖：仅 Python 标准库 + httpx（已在 env_vllm2 中安装）
"""

import argparse
import http.server
import io
import json
import math
import os
import socketserver
import socket
import sys
import threading
import warnings
from typing import Iterator

import httpx

# 屏蔽 funasr/modelscope exec() 内部产生的无关 SyntaxWarning
warnings.filterwarnings("ignore", category=SyntaxWarning)

# ─── 配置（可通过命令行参数覆盖）────────────────────────────────────────────
VLLM_BASE_URL    = "http://localhost:8010/v1"
MODEL_NAME       = "gpt-oss-20b"
SERVER_HOST      = "0.0.0.0"
SERVER_PORT      = 5000
TEMPERATURE      = 0.7      # 采样温度
MAX_TOKENS       = 1024     # 单次最大输出 token 数
MAX_HISTORY_TURNS = 20      # 保留的最大对话轮数（超出自动裁剪）
SYSTEM_PROMPT    = ""       # 系统提示词，留空则不注入
ASR_MODEL        = "paraformer-zh"  # FunASR 模型（首次运行自动下载）
ASR_ENABLED      = True     # False 则禁用 FunASR 端点
# ─────────────────────────────────────────────────────────────────────────────

HTML_PAGE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>GPT-OSS-20B 语音聊天</title>
<style>
  :root {
    --bg: #0f1117; --surface: #1a1d27; --border: #2d3045;
    --accent: #7c6af7; --accent2: #5dd8c8; --text: #e2e8f0; --muted: #8892a4;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: 'Segoe UI', system-ui, sans-serif; min-height: 100vh; display: flex; flex-direction: column; align-items: center; padding: 24px 16px; }
  h1 { font-size: 1.5rem; font-weight: 600; margin-bottom: 4px; background: linear-gradient(90deg, var(--accent), var(--accent2)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
  .subtitle { color: var(--muted); font-size: 0.85rem; margin-bottom: 20px; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 16px; width: 100%; max-width: 820px; margin-bottom: 16px; }
  canvas { width: 100%; height: 80px; display: block; border-radius: 8px; background: #0a0c12; }
  .controls { display: flex; gap: 10px; margin-top: 12px; align-items: flex-end; flex-wrap: wrap; }
  button { padding: 8px 18px; border-radius: 8px; border: none; cursor: pointer; font-size: 0.9rem; font-weight: 500; transition: opacity .2s, transform .1s; white-space: nowrap; }
  button:active { transform: scale(0.97); }
  button:disabled { opacity: 0.4; cursor: default; }
  #micBtn  { background: var(--accent); color: #fff; }
  #micBtn.active { background: #e05050; }
  #sendBtn { background: var(--accent2); color: #0f1117; }
  #clearBtn{ background: #2d3045; color: var(--text); }
  .status-bar { display: flex; align-items: center; gap: 8px; margin-top: 6px; flex-wrap: wrap; }
  #status  { font-size: 0.82rem; color: var(--muted); }
  #tokenCount { font-size: 0.78rem; color: var(--border); margin-left: auto; }
  #asrBadge { font-size: 0.75rem; padding: 2px 8px; border-radius: 20px; background: #1a2520; color: #5dd8c8; border: 1px solid #2d4540; white-space: nowrap; }
  #transcript { flex: 1; min-width: 160px; background: #0a0c12; border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text); font-size: 0.9rem; outline: none; resize: none; overflow-y: hidden; line-height: 1.4; font-family: inherit; min-height: 36px; max-height: 120px; }
  .chat-box  { max-height: 420px; overflow-y: auto; display: flex; flex-direction: column; gap: 12px; }
  .msg { padding: 10px 14px; border-radius: 10px; line-height: 1.6; font-size: 0.92rem; max-width: 88%; white-space: pre-wrap; word-break: break-word; }
  .msg.user { background: #2a2560; align-self: flex-end; border-bottom-right-radius: 2px; }
  .msg.assistant { background: #1e2535; align-self: flex-start; border-bottom-left-radius: 2px; }
  .msg.thinking { background: #1a2520; color: #7ecfc4; font-size: 0.82rem; font-style: italic; opacity: 0.8; }
  .msg .role { font-size: 0.75rem; font-weight: 600; margin-bottom: 4px; opacity: 0.7; text-transform: uppercase; letter-spacing: .05em; }
  .blink::after { content: '▌'; animation: blink .6s step-end infinite; }
  @keyframes blink { 50% { opacity: 0; } }
  .empty-hint { color: var(--muted); font-size: 0.88rem; text-align: center; padding: 24px 0; }
</style>
</head>
<body>

<h1>GPT-OSS-20B 语音聊天</h1>
<p class="subtitle">麦克风波形可视化 · FunASR 语音识别 · 流式推理</p>

<!-- 波形卡片 -->
<div class="card">
  <canvas id="wave"></canvas>
  <div class="controls">
    <button id="micBtn">🎤 开始录音</button>
    <textarea id="transcript" rows="1" placeholder="或在此输入文字…（Enter 发送，Shift+Enter 换行）" autocomplete="off"></textarea>
    <button id="sendBtn">发送 ▶</button>
    <button id="clearBtn">清空</button>
  </div>
  <div class="status-bar">
    <span id="status">就绪</span>
    <span id="asrBadge">ASR 加载中…</span>
    <span id="tokenCount"></span>
  </div>
</div>

<!-- ASR 质量提示 -->
<div style="width:100%;max-width:820px;margin-bottom:12px;padding:8px 14px;background:#2a1a1a;border:1px solid #5a2a2a;border-radius:8px;color:#e08080;font-size:0.82rem;">
  ⚠️ 注意：这一般的语音识别仅作参考，效果很差。
</div>

<!-- 对话卡片 -->
<div class="card">
  <div class="chat-box" id="chatBox">
    <div class="empty-hint" id="emptyHint">发送消息开始对话</div>
  </div>
</div>

<script>
// ── 波形可视化 ──────────────────────────────────────────────────────────────
const canvas = document.getElementById('wave');
const ctx2d  = canvas.getContext('2d');
let audioCtx, analyser, dataArr, rafId, micStream;

function resizeCanvas() {
  canvas.width  = canvas.clientWidth  * devicePixelRatio;
  canvas.height = canvas.clientHeight * devicePixelRatio;
}
window.addEventListener('resize', resizeCanvas);
resizeCanvas();

function drawWave() {
  rafId = requestAnimationFrame(drawWave);
  const W = canvas.width, H = canvas.height;
  ctx2d.clearRect(0, 0, W, H);
  if (!analyser) { drawIdle(W, H); return; }
  analyser.getByteTimeDomainData(dataArr);
  ctx2d.lineWidth = 2 * devicePixelRatio;
  ctx2d.strokeStyle = '#7c6af7';
  ctx2d.beginPath();
  const slice = W / dataArr.length;
  let x = 0;
  for (let i = 0; i < dataArr.length; i++) {
    const y = (dataArr[i] / 128.0) * (H / 2);
    i === 0 ? ctx2d.moveTo(x, y) : ctx2d.lineTo(x, y);
    x += slice;
  }
  ctx2d.lineTo(W, H / 2);
  ctx2d.stroke();
}

function drawIdle(W, H) {
  ctx2d.strokeStyle = '#2d3045';
  ctx2d.lineWidth = 1.5 * devicePixelRatio;
  ctx2d.beginPath();
  ctx2d.moveTo(0, H / 2);
  ctx2d.lineTo(W, H / 2);
  ctx2d.stroke();
}

drawWave();

// ── 麦克风 + FunASR 语音识别 ─────────────────────────────────────────────
const micBtn    = document.getElementById('micBtn');
const status    = document.getElementById('status');
const tokenCount = document.getElementById('tokenCount');
const asrBadge  = document.getElementById('asrBadge');
let recording   = false;

// PCM 捕获状态
let pcmChunks  = [];   // Float32Array 片段（原始采样率）
let nativeSR   = 0;    // AudioContext 采样率（通常 48000）
let scriptProc = null; // ScriptProcessorNode

async function startMic() {
  micStream = await navigator.mediaDevices.getUserMedia({
    audio: {
      channelCount: 1,
      echoCancellation: false,   // 关闭回声消除，保留原始声纹
      noiseSuppression: false,   // 关闭降噪，ASR 模型自带噪声鲁棒性
      autoGainControl: false,    // 关闭自动增益，防止音量突变影响 VAD
    },
    video: false
  });
  audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  nativeSR = audioCtx.sampleRate;
  analyser = audioCtx.createAnalyser();
  analyser.fftSize = 2048;
  dataArr  = new Uint8Array(analyser.frequencyBinCount);
  const src = audioCtx.createMediaStreamSource(micStream);
  src.connect(analyser);

  // ScriptProcessorNode 捕获 PCM
  // 无回放设备，直接接 destination 激活音频图即可
  pcmChunks  = [];
  scriptProc = audioCtx.createScriptProcessor(4096, 1, 1);
  scriptProc.onaudioprocess = e => {
    pcmChunks.push(new Float32Array(e.inputBuffer.getChannelData(0)));
  };
  src.connect(scriptProc);
  scriptProc.connect(audioCtx.destination);
}

function stopMic() {
  if (scriptProc) { scriptProc.disconnect(); scriptProc = null; }
  if (micStream)  micStream.getTracks().forEach(t => t.stop());
  if (audioCtx)   audioCtx.close();
  analyser = null; audioCtx = null; micStream = null;
}

// OfflineAudioContext 在浏览器内把 PCM 降采样到 16 kHz（高质量 sinc 插值）
async function resampleTo16k(chunks, srcSR) {
  const TARGET = 16000;
  let total = 0;
  for (const c of chunks) total += c.length;
  const flat = new Float32Array(total);
  let off = 0;
  for (const c of chunks) { flat.set(c, off); off += c.length; }
  if (srcSR === TARGET) return flat;

  const outLen  = Math.ceil(total * TARGET / srcSR);
  const offCtx  = new OfflineAudioContext(1, outLen, TARGET);
  const abuf    = offCtx.createBuffer(1, total, srcSR);
  abuf.copyToChannel(flat, 0);
  const bsrc    = offCtx.createBufferSource();
  bsrc.buffer   = abuf;
  bsrc.connect(offCtx.destination);
  bsrc.start(0);
  const rendered = await offCtx.startRendering();
  return rendered.getChannelData(0);
}

// Float32 PCM 片段 → 16-bit WAV ArrayBuffer
function encodeWAV(chunks, sr) {
  let total = 0;
  for (const c of chunks) total += c.length;
  const pcm = new Float32Array(total);
  let off = 0;
  for (const c of chunks) { pcm.set(c, off); off += c.length; }

  const buf = new ArrayBuffer(44 + total * 2);
  const v   = new DataView(buf);
  const ws  = (pos, s) => { for (let i = 0; i < s.length; i++) v.setUint8(pos + i, s.charCodeAt(i)); };

  ws(0, 'RIFF'); v.setUint32(4,  36 + total * 2, true);
  ws(8, 'WAVE'); ws(12, 'fmt ');
  v.setUint32(16, 16,     true); // PCM chunk size
  v.setUint16(20, 1,      true); // format: PCM
  v.setUint16(22, 1,      true); // channels: mono
  v.setUint32(24, sr,     true); // sample rate
  v.setUint32(28, sr * 2, true); // byte rate
  v.setUint16(32, 2,      true); // block align
  v.setUint16(34, 16,     true); // bits per sample
  ws(36, 'data'); v.setUint32(40, total * 2, true);
  for (let i = 0; i < pcm.length; i++) {
    const s = Math.max(-1, Math.min(1, pcm[i]));
    v.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
  }
  return buf;
}

// 将 WAV 发送到 /asr，结果填入输入框
async function runASR(chunks, sr) {
  if (!chunks.length) return;
  status.textContent = '\u23f3 \u91cd\u91c7\u6837\u5230 16kHz\u2026';
  micBtn.disabled = true;
  try {
    const pcm16 = await resampleTo16k(chunks, sr); // 浏览器内高质量降采样
    const wav  = encodeWAV([pcm16], 16000);
    status.textContent = '\ud83d\udd0d FunASR \u8bc6\u522b\u4e2d\u2026';
    const resp = await fetch('/asr', {
      method:  'POST',
      headers: { 'Content-Type': 'audio/wav' },
      body:    wav,
    });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${await resp.text()}`);
    const data = await resp.json();
    const txt  = (data.text || '').trim();
    if (txt) {
      inputEl.value = inputEl.value.trim() ? inputEl.value.trim() + ' ' + txt : txt;
      autoResize(inputEl);
      status.textContent = '✓ 识别完成 — 按 Enter 发送';
    } else {
      status.textContent = '未识别到语音内容';
    }
  } catch (e) {
    status.textContent = `ASR 错误: ${e.message}`;
  } finally {
    micBtn.disabled = false;
  }
}

// 页面加载时探测 ASR 后端状态
(async () => {
  try {
    const r = await fetch('/health');
    const d = await r.json();
    asrBadge.textContent = d.asr_model ? `ASR: ${d.asr_model}` : 'ASR: 已禁用';
  } catch (_) {
    asrBadge.textContent = 'ASR: 未知';
  }
})();

micBtn.addEventListener('click', async () => {
  if (!recording) {
    try {
      await startMic();
      micBtn.textContent = '⏹ 停止录音';
      micBtn.classList.add('active');
      status.textContent = '录音中… 停止后自动 FunASR 识别';
      recording = true;
    } catch (e) {
      status.textContent = `错误: ${e.message}`;
    }
  } else {
    recording = false;
    const savedChunks = pcmChunks.slice();
    const savedSR     = nativeSR;
    stopMic();
    micBtn.textContent = '🎤 开始录音';
    micBtn.classList.remove('active');
    await runASR(savedChunks, savedSR);
  }
});

// ── 聊天逻辑 ───────────────────────────────────────────────────────────────
const chatBox   = document.getElementById('chatBox');
const sendBtn   = document.getElementById('sendBtn');
const clearBtn  = document.getElementById('clearBtn');
const inputEl   = document.getElementById('transcript');

let history   = [];   // [{role, content}]
let streaming = false;
let abortCtrl = null;

// Auto-resize textarea as user types
function autoResize(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 120) + 'px';
}
inputEl.addEventListener('input', () => autoResize(inputEl));

// Returns true if chatBox is scrolled near the bottom
function isNearBottom() {
  return chatBox.scrollHeight - chatBox.scrollTop - chatBox.clientHeight < 80;
}

function scrollIfPinned() {
  if (isNearBottom()) chatBox.scrollTop = chatBox.scrollHeight;
}

function addMsg(role, content, tempId) {
  const hint = document.getElementById('emptyHint');
  if (hint) hint.remove();
  const div = document.createElement('div');
  div.className = `msg ${role}`;
  if (tempId) div.id = tempId;
  const label = { user: '你', assistant: 'GPT-OSS-20B', thinking: '思考中' }[role] || role;
  div.innerHTML = `<div class="role">${label}</div><span class="body"></span>`;
  div.querySelector('.body').textContent = content;
  chatBox.appendChild(div);
  scrollIfPinned();
  return div;
}

function updateMsg(id, text, done) {
  const el = document.getElementById(id);
  if (!el) return;
  const body = el.querySelector('.body');
  body.textContent = text;
  done ? body.classList.remove('blink') : body.classList.add('blink');
  scrollIfPinned();
}

async function send(text) {
  text = text.trim();
  if (!text || streaming) return;

  // ── abort previous if somehow still running
  if (abortCtrl) abortCtrl.abort();
  abortCtrl = new AbortController();

  streaming = true;
  sendBtn.textContent = '⏹ 停止';
  sendBtn.disabled = false;
  sendBtn.style.background = '#e05050';
  inputEl.value = '';
  autoResize(inputEl);
  finalTranscript = '';
  status.textContent = '生成中…';
  tokenCount.textContent = '';

  addMsg('user', text);
  history.push({ role: 'user', content: text });

  const thinkId = 'think-' + Date.now();
  const replyId = 'reply-' + Date.now();
  let thinkDiv = null, replyDiv = null;
  let thinkBuf = '', replyBuf = '';
  let tokCount = 0;

  const resetSendBtn = () => {
    streaming = false;
    abortCtrl = null;
    sendBtn.textContent = '发送 ▶';
    sendBtn.style.background = '';
    sendBtn.disabled = false;
  };

  // Clicking send/stop during streaming cancels the request
  const abortHandler = () => {
    if (streaming && abortCtrl) {
      abortCtrl.abort();
      status.textContent = '已中断';
      if (thinkDiv) updateMsg(thinkId, thinkBuf, true);
      if (replyDiv) updateMsg(replyId, replyBuf + ' [中断]', true);
      if (replyBuf) history.push({ role: 'assistant', content: replyBuf });
      resetSendBtn();
    } else {
      send(inputEl.value);
    }
  };
  sendBtn.onclick = abortHandler;

  try {
    const res = await fetch('/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messages: history }),
      signal: abortCtrl.signal,
    });

    if (!res.ok) throw new Error(`HTTP ${res.status}`);

    const reader = res.body.getReader();
    const dec    = new TextDecoder();
    let buf = '';

    outer: while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split('\n');
      buf = lines.pop();

      for (const line of lines) {
        if (!line.startsWith('data: ')) continue;
        const raw = line.slice(6).trim();
        if (raw === '[DONE]') break outer;
        try {
          const evt = JSON.parse(raw);
          if (evt.type === 'thinking') {
            thinkBuf += evt.text;
            if (!thinkDiv) thinkDiv = addMsg('thinking', '', thinkId);
            updateMsg(thinkId, thinkBuf, false);
          } else if (evt.type === 'content') {
            replyBuf += evt.text;
            tokCount++;
            if (!replyDiv) replyDiv = addMsg('assistant', '', replyId);
            updateMsg(replyId, replyBuf, false);
            tokenCount.textContent = `~${tokCount} tokens`;
          } else if (evt.type === 'done') {
            if (thinkDiv) updateMsg(thinkId, thinkBuf, true);
            if (replyDiv) updateMsg(replyId, replyBuf, true);
          } else if (evt.type === 'error') {
            throw new Error(evt.text);
          }
        } catch (parseErr) {
          if (parseErr.message && parseErr.message !== 'Unknown') throw parseErr;
        }
      }
    }

    if (replyBuf) history.push({ role: 'assistant', content: replyBuf });
    status.textContent = '就绪';

  } catch (e) {
    if (e.name !== 'AbortError') {
      addMsg('assistant', `⚠ 请求失败: ${e.message}`);
      status.textContent = '错误';
    }
  }

  resetSendBtn();
  sendBtn.onclick = () => send(inputEl.value);
}

sendBtn.addEventListener('click', () => send(inputEl.value));
inputEl.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(inputEl.value); }
});
clearBtn.addEventListener('click', () => {
  if (abortCtrl) { abortCtrl.abort(); abortCtrl = null; }
  streaming = false;
  history = [];
  chatBox.innerHTML = '<div class="empty-hint" id="emptyHint">发送消息开始对话</div>';
  status.textContent = '已清空';
  tokenCount.textContent = '';
  sendBtn.textContent = '发送 ▶';
  sendBtn.style.background = '';
  sendBtn.onclick = () => send(inputEl.value);
});
</script>
</body>
</html>
"""


# ─── FunASR 语音识别 ─────────────────────────────────────────────────────────
_asr_model: object = None
_asr_lock = threading.Lock()


def _install_torchaudio_stub() -> None:
    """如果真实 torchaudio 无法加载（常见于 CUDA 版本不匹配），
    向 sys.modules 注入一个基于 soundfile + scipy 的轻量接口实现。
    FunASR 内部使用的就是这个模块：仅 torchaudio.load() 和 torchaudio.transforms.Resample。
    """
    if "torchaudio" in sys.modules:
        return
    try:
        import torchaudio  # noqa
        return
    except OSError:
        pass

    import types
    import numpy as np
    import soundfile as sf
    import torch
    from scipy.signal import resample_poly as _resample_poly

    stub = types.ModuleType("torchaudio")
    stub.__path__ = []   # mark as package so sub-imports resolve via sys.modules

    class _Resample:
        """scipy-based drop-in for torchaudio.transforms.Resample."""
        def __init__(self, orig_sr: int, new_sr: int):
            self.orig_sr = orig_sr
            self.new_sr  = new_sr

        def __call__(self, waveform: object) -> object:
            import torch as _torch
            if self.orig_sr == self.new_sr:
                return waveform
            g   = math.gcd(self.new_sr, self.orig_sr)
            arr = waveform.numpy()
            out = _resample_poly(arr, self.new_sr // g, self.orig_sr // g, axis=-1)
            return _torch.from_numpy(out.astype(np.float32))

    class _Transforms:
        Resample = _Resample

    def _load(path, fmt=None, **kwargs):  # noqa
        """soundfile-based audio loader -> (Tensor[C,T], sample_rate)."""
        src = path if (isinstance(path, io.IOBase) or hasattr(path, "read")) else path
        data, sr = sf.read(src, dtype="float32", always_2d=True)
        return torch.from_numpy(data.T), sr   # sf gives [T,C] -> transpose to [C,T]

    stub.load       = _load
    stub.transforms = _Transforms()

    # torchaudio.compliance.kaldi — used by wav_frontend for fbank feature extraction.
    # kaldi.py is pure Python (no .so), so we can load it directly via importlib.
    import importlib.util as _ilu, pathlib as _pl
    _ta_dir = _pl.Path(
        "/home/tester/miniconda3/envs/env_vllm2/lib/python3.12"
        "/site-packages/torchaudio"
    )

    # Point stub's __path__ at the real torchaudio directory so relative imports work.
    stub.__path__ = [str(_ta_dir)]
    stub.__package__ = "torchaudio"

    comply_stub = types.ModuleType("torchaudio.compliance")
    comply_stub.__path__ = [str(_ta_dir / "compliance")]
    comply_stub.__package__ = "torchaudio.compliance"

    # Pre-register stubs before loading kaldi.py so any intra-package imports resolve.
    sys.modules["torchaudio"]              = stub
    sys.modules["torchaudio.transforms"]   = _Transforms  # type: ignore
    sys.modules["torchaudio.compliance"]   = comply_stub

    # Load the real kaldi.py (pure torch, no .so dependency).
    _kaldi_spec = _ilu.spec_from_file_location(
        "torchaudio.compliance.kaldi",
        str(_ta_dir / "compliance" / "kaldi.py"),
    )
    kaldi_mod = _ilu.module_from_spec(_kaldi_spec)
    kaldi_mod.__package__ = "torchaudio.compliance"
    _kaldi_spec.loader.exec_module(kaldi_mod)  # type: ignore

    comply_stub.kaldi = kaldi_mod
    sys.modules["torchaudio.compliance.kaldi"] = kaldi_mod
    print("[ASR] torchaudio stub active (soundfile+scipy+real kaldi.fbank)", flush=True)


def get_asr_model():
    """懒加载 FunASR 模型（首次调用时下载，约 400 MB）。"""
    global _asr_model
    if _asr_model is None:
        with _asr_lock:
            if _asr_model is None:
                _install_torchaudio_stub()           # 必须在 import funasr 之前
                from funasr import AutoModel  # type: ignore
                print(f"[ASR] 正在加载 {ASR_MODEL}...", flush=True)
                _asr_model = AutoModel(
                    model=ASR_MODEL,
                    vad_model="fsmn-vad",
                    punc_model="ct-punc",
                    disable_update=True,
                )
                print("[ASR] 模型加载完成", flush=True)
    return _asr_model


def run_asr(wav_bytes: bytes) -> str:
    """WAV 字节（浏览器已降采样到 16kHz）直接输入 FunASR。"""
    import numpy as np
    import soundfile as sf

    TARGET_SR = 16000

    buf = io.BytesIO(wav_bytes)
    data, native_sr = sf.read(buf, dtype="float32", always_2d=False)
    if data.ndim > 1:
        data = data.mean(axis=1)

    # 防御：万一浏览器传来的不是 16kHz，进行备用重采样
    if native_sr != TARGET_SR:
        from scipy.signal import resample_poly
        g    = math.gcd(TARGET_SR, native_sr)
        data = resample_poly(data, TARGET_SR // g, native_sr // g).astype(np.float32)

    model   = get_asr_model()
    results = model.generate(
        input        = data,
        batch_size_s = 300,
        use_itn      = True,
    )
    return results[0]["text"] if results else ""


# ─── SSE 流式转发 ─────────────────────────────────────────────────────────────
def _trim_history(messages: list) -> list:
    """保留系统消息 + 最近 MAX_HISTORY_TURNS 轮对话（每轮 = user+assistant 各一条）。"""
    sys_msgs = [m for m in messages if m["role"] == "system"]
    conv     = [m for m in messages if m["role"] != "system"]
    max_msgs = MAX_HISTORY_TURNS * 2          # turns → individual messages
    if len(conv) > max_msgs:
        conv = conv[-max_msgs:]
    return sys_msgs + conv


def stream_chat(messages: list) -> Iterator[str]:
    """调用 vLLM chat completions，以 SSE 格式 yield 事件数据。"""
    # 注入系统提示词
    if SYSTEM_PROMPT:
        messages = [{"role": "system", "content": SYSTEM_PROMPT}] + [
            m for m in messages if m["role"] != "system"
        ]
    # 裁剪过长历史
    messages = _trim_history(messages)

    payload = {
        "model": MODEL_NAME,
        "messages": messages,
        "stream": True,
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
    }
    in_thinking = False

    try:
        with httpx.Client(timeout=120) as client:
            with client.stream(
                "POST",
                f"{VLLM_BASE_URL}/chat/completions",
                json=payload,
                headers={"Content-Type": "application/json"},
            ) as resp:
                resp.raise_for_status()
                for line in resp.iter_lines():
                    if not line or not line.startswith("data: "):
                        continue
                    raw = line[6:].strip()
                    if raw == "[DONE]":
                        yield "data: " + json.dumps({"type": "done"}) + "\n\n"
                        return
                    try:
                        chunk = json.loads(raw)
                    except json.JSONDecodeError:
                        continue

                    delta = chunk.get("choices", [{}])[0].get("delta", {})
                    text  = delta.get("content") or delta.get("reasoning_content") or ""
                    if not text:
                        continue

                    # Parse <think>…</think> delimiters for chain-of-thought display
                    i = 0
                    while i < len(text):
                        if not in_thinking:
                            think_start = text.find("<think>", i)
                            if think_start == -1:
                                frag = text[i:]
                                yield f"data: {json.dumps({'type':'content','text':frag})}\n\n"
                                i = len(text)
                            else:
                                before = text[i:think_start]
                                if before:
                                    yield f"data: {json.dumps({'type':'content','text':before})}\n\n"
                                in_thinking = True
                                i = think_start + len("<think>")
                        else:
                            think_end = text.find("</think>", i)
                            if think_end == -1:
                                frag = text[i:]
                                yield f"data: {json.dumps({'type':'thinking','text':frag})}\n\n"
                                i = len(text)
                            else:
                                frag = text[i:think_end]
                                if frag:
                                    yield f"data: {json.dumps({'type':'thinking','text':frag})}\n\n"
                                in_thinking = False
                                i = think_end + len("</think>")

        yield "data: " + json.dumps({"type": "done"}) + "\n\n"

    except Exception as exc:
        yield f"data: {json.dumps({'type':'error','text':str(exc)})}\n\n"


# ─── HTTP 请求处理器 ──────────────────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[{self.address_string()}] {fmt % args}")

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            body = HTML_PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/health":
            # Quick liveness + vLLM backend check
            try:
                r = httpx.get(f"{VLLM_BASE_URL}/models", timeout=3)
                ok = r.status_code == 200
            except Exception:
                ok = False
            result = json.dumps({"status": "ok" if ok else "vllm_unavailable",
                                  "vllm": VLLM_BASE_URL,
                                  "asr_model": ASR_MODEL if ASR_ENABLED else None}).encode()
            self.send_response(200 if ok else 503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(result)))
            self.end_headers()
            self.wfile.write(result)
        else:
            self.send_error(404)

    def do_POST(self):
        path = self.path.split("?")[0]

        # ── /asr: FunASR 语音识别 ────────────────────────────────────────────
        if path == "/asr":
            if not ASR_ENABLED:
                self.send_error(503, "ASR disabled")
                return
            length = int(self.headers.get("Content-Length", 0))
            wav_bytes = self.rfile.read(length)
            try:
                text = run_asr(wav_bytes)
            except Exception as exc:
                resp = json.dumps({"error": str(exc)}).encode()
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp)))
                self.end_headers()
                self.wfile.write(resp)
                return
            resp = json.dumps({"text": text}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return

        # ── /chat: vLLM 流式对话 ─────────────────────────────────────────────
        if path != "/chat":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            body     = json.loads(self.rfile.read(length))
            messages = body.get("messages", [])
        except Exception:
            self.send_error(400, "Invalid JSON")
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        try:
            for chunk in stream_chat(messages):
                self.wfile.write(chunk.encode())
                self.wfile.flush()
        except BrokenPipeError:
            pass  # client disconnected


# ─── 入口 ─────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="GPT-OSS-20B 语音聊天 Demo")
    ap.add_argument("--port",    type=int, default=SERVER_PORT,   help="监听端口")
    ap.add_argument("--url",     type=str, default=VLLM_BASE_URL, help="vLLM 地址")
    ap.add_argument("--model",   type=str, default=MODEL_NAME,    help="模型名")
    ap.add_argument("--temp",    type=float, default=TEMPERATURE, help="temperature")
    ap.add_argument("--max-tok", type=int, default=MAX_TOKENS,    help="max_tokens")
    ap.add_argument("--system",    type=str,  default=SYSTEM_PROMPT, help="系统提示词")
    ap.add_argument("--asr-model", type=str,  default=ASR_MODEL,     help="FunASR 模型名（默认 paraformer-zh）")
    ap.add_argument("--no-asr",    action="store_true",               help="禁用 FunASR 端点")
    args = ap.parse_args()

    # Apply CLI overrides
    VLLM_BASE_URL = args.url
    MODEL_NAME    = args.model
    SERVER_PORT   = args.port
    TEMPERATURE   = args.temp
    MAX_TOKENS    = args.max_tok
    SYSTEM_PROMPT = args.system
    ASR_MODEL     = args.asr_model
    ASR_ENABLED   = not args.no_asr

    # Detect LAN IP for display
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        lan_ip = s.getsockname()[0]
        s.close()
    except Exception:
        lan_ip = "127.0.0.1"

    # Probe vLLM backend before starting
    print("正在检查 vLLM 后端…", end=" ", flush=True)
    try:
        r = httpx.get(f"{VLLM_BASE_URL}/models", timeout=5)
        if r.status_code == 200:
            models = [m["id"] for m in r.json().get("data", [])]
            print(f"✓  可用模型: {', '.join(models)}")
        else:
            print(f"⚠  响应 {r.status_code}，继续启动…")
    except Exception as e:
        print(f"⚠  连接失败 ({e})，继续启动（推理时会重试）…")

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer((SERVER_HOST, SERVER_PORT), Handler) as srv:
        print("=" * 52)
        print(" GPT-OSS-20B 语音聊天 Demo")
        print("=" * 52)
        print(f"  本机:   http://localhost:{SERVER_PORT}")
        print(f"  局域网: http://{lan_ip}:{SERVER_PORT}")
        print(f"  后端:   {VLLM_BASE_URL}  model={MODEL_NAME}")
        print(f"  参数:   temp={TEMPERATURE}  max_tokens={MAX_TOKENS}")
        print(f"  健康:   http://localhost:{SERVER_PORT}/health")
        print(f"  ASR:    {'已启用 (' + ASR_MODEL + ')' if ASR_ENABLED else '已禁用'}")
        print("  Ctrl+C 退出")
        print("=" * 52)
        try:
            if ASR_ENABLED:
                print(f"[ASR] 后台预加载 {ASR_MODEL}…", flush=True)
                threading.Thread(target=get_asr_model, daemon=True, name="asr-preload").start()
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止")