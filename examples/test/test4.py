
from flask import Flask, render_template_string

app = Flask(__name__)

# 直接把完整的 HTML 写进字符串（方便一次性运行）
INDEX_HTML = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>麦克风实时波形</title>
<style>
  body {font-family: Arial, sans-serif; text-align: center; background:#f4f4f4;}
  #canvas {border:1px solid #333; background:#000; margin-top:20px;}
  button{margin:10px;padding:8px 15px;font-size:1rem;}
</style>
</head>
<body>
<h1>麦克风实时波形示例</h1>
<button id="startBtn">开启麦克风</button>
<button id="stopBtn" disabled>停止采集</button>
<canvas id="canvas" width="800" height="200"></canvas>

<script>
let audioCtx;
let analyser;
let dataArray;
let bufferLength;
let raf