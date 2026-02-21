#!/usr/bin/env python3
"""
Streamlit 实时麦克风音频波形显示应用
支持多设备选择和实时波形更新
"""

import streamlit as st
import numpy as np
import pyaudio
import threading
from collections import deque
import matplotlib.pyplot as plt
import time

st.set_page_config(page_title="Audio Waveform Viewer", layout="wide")
st.title("🎤 Real-time Microphone Waveform")

# 全局变量（用于线程通信）
is_recording = False
audio_data = deque(maxlen=44100)
stream = None
p = None

# 音频参数
CHUNK = 1024
FORMAT = pyaudio.paFloat32
CHANNELS = 1
RATE = 44100

# 获取可用的音频设备
def get_audio_devices():
    """获取所有可用的音频输入设备"""
    p = pyaudio.PyAudio()
    devices = {}
    
    for i in range(p.get_device_count()):
        info = p.get_device_info_by_index(i)
        if info['maxInputChannels'] > 0:  # 只显示输入设备
            device_name = f"{i}: {info['name']} (Channels: {info['maxInputChannels']})"
            devices[device_name] = i
    
    p.terminate()
    return devices

# 初始化会话状态
if "is_recording" not in st.session_state:
    st.session_state.is_recording = False
    st.session_state.selected_device = None

def audio_callback(device_id):
    """音频捕获线程"""
    global is_recording, audio_data, stream, p
    
    try:
        p_local = pyaudio.PyAudio()
        stream_local = p_local.open(
            format=FORMAT,
            channels=CHANNELS,
            rate=RATE,
            input=True,
            input_device_index=device_id if device_id is not None else None,
            frames_per_buffer=CHUNK
        )
        
        stream = stream_local
        p = p_local
        
        while st.session_state.is_recording:
            try:
                data = stream_local.read(CHUNK, exception_on_overflow=False)
                audio_array = np.frombuffer(data, dtype=np.float32)
                audio_data.extend(audio_array)
            except Exception as e:
                print(f"音频捕获错误: {e}")
                break
        
        stream_local.stop_stream()
        stream_local.close()
        p_local.terminate()
    except Exception as e:
        print(f"无法初始化音频设备: {e}")

# 侧边栏设置
st.sidebar.header("⚙️ 设置")

# 获取设备列表
devices = get_audio_devices()
if devices:
    device_options = list(devices.keys())
    selected_device_name = st.sidebar.selectbox(
        "选择音频输入设备",
        device_options,
        index=0
    )
    st.session_state.selected_device = devices[selected_device_name]
else:
    st.sidebar.error("未找到任何音频输入设备！")
    st.session_state.selected_device = None

# 采样率和缓冲区大小设置
st.sidebar.divider()
sample_rate = st.sidebar.slider("采样率 (Hz)", 8000, 48000, 44100, step=1000)
buffer_size = st.sidebar.slider("显示缓冲区 (ms)", 100, 5000, 1000, step=100)
buffer_samples = int(sample_rate * buffer_size / 1000)

# 界面布局
col1, col2, col3 = st.columns([1, 1, 1])

with col1:
    if st.button("🎙️ 开始录音", key="start_btn"):
        if st.session_state.selected_device is not None:
            st.session_state.is_recording = True
            audio_data.clear()
            thread = threading.Thread(
                target=audio_callback, 
                args=(st.session_state.selected_device,),
                daemon=True
            )
            thread.start()
            st.success("✅ 录音已启动！")
        else:
            st.error("❌ 请先选择音频设备")

with col2:
    if st.button("⏹️ 停止录音", key="stop_btn"):
        st.session_state.is_recording = False
        if stream:
            try:
                stream.stop_stream()
                stream.close()
            except:
                pass
        if p:
            try:
                p.terminate()
            except:
                pass
        st.info("⏸️ 录音已停止！")

with col3:
    if st.button("🗑️ 清除数据", key="clear_btn"):
        audio_data.clear()
        st.info("🧹 数据已清除！")

st.divider()

# 动态波形显示区域
st.subheader("📊 实时波形显示")

# 创建波形图表的占位符
waveform_placeholder = st.empty()
stats_placeholder = st.empty()

# 显示波形
if st.session_state.is_recording:
    # 使用占位符实时更新波形
    while st.session_state.is_recording and len(audio_data) > buffer_samples:
        with waveform_placeholder.container():
            fig, ax = plt.subplots(figsize=(14, 4))
            audio_array = np.array(list(audio_data)[-buffer_samples:])
            time_axis = np.arange(len(audio_array)) / sample_rate
            ax.plot(time_axis, audio_array, linewidth=0.8, color='cyan', label='波形')
            ax.set_xlabel("时间 (秒)", fontsize=11)
            ax.set_ylabel("振幅", fontsize=11)
            ax.set_title(f"麦克风音频波形 - 设备: {selected_device_name}", fontsize=12, fontweight='bold')
            ax.grid(True, alpha=0.3)
            ax.set_ylim(-1, 1)
            ax.legend(loc='upper right')
            plt.tight_layout()
            st.pyplot(fig)
        
        with stats_placeholder.container():
            col1, col2, col3, col4 = st.columns(4)
            with col1:
                st.metric("采样率", f"{sample_rate} Hz")
            with col2:
                st.metric("音频长度", f"{len(audio_data) / sample_rate:.2f} 秒")
            with col3:
                st.metric("最大振幅", f"{np.max(np.abs(audio_array)):.3f}")
            with col4:
                rms = np.sqrt(np.mean(audio_array**2))
                st.metric("RMS 能量", f"{rms:.3f}")
        
        time.sleep(0.5)
else:
    if len(audio_data) > 0:
        fig, ax = plt.subplots(figsize=(14, 4))
        audio_array = np.array(list(audio_data)[-buffer_samples:])
        time_axis = np.arange(len(audio_array)) / sample_rate
        ax.plot(time_axis, audio_array, linewidth=0.8, color='cyan', label='波形')
        ax.set_xlabel("时间 (秒)", fontsize=11)
        ax.set_ylabel("振幅", fontsize=11)
        ax.set_title(f"麦克风音频波形 - 设备: {selected_device_name}", fontsize=12, fontweight='bold')
        ax.grid(True, alpha=0.3)
        ax.set_ylim(-1, 1)
        ax.legend(loc='upper right')
        plt.tight_layout()
        waveform_placeholder.pyplot(fig)
        
        with stats_placeholder.container():
            col1, col2, col3, col4 = st.columns(4)
            with col1:
                st.metric("采样率", f"{sample_rate} Hz")
            with col2:
                st.metric("音频长度", f"{len(audio_data) / sample_rate:.2f} 秒")
            with col3:
                st.metric("最大振幅", f"{np.max(np.abs(audio_array)):.3f}")
            with col4:
                rms = np.sqrt(np.mean(audio_array**2))
                st.metric("RMS 能量", f"{rms:.3f}")
    else:
        waveform_placeholder.info("⏳ 点击「开始录音」开始采集音频...")

# 状态指示
st.divider()
col1, col2, col3 = st.columns(3)

with col1:
    if st.session_state.is_recording:
        st.success("🔴 **正在录音中...**")
    else:
        st.warning("⭕ **未录音**")

with col2:
    st.info(f"📦 缓存数据: {len(audio_data)}/{buffer_samples} 样本")

with col3:
    if st.session_state.selected_device is not None:
        st.success(f"✅ 设备已选择")
    else:
        st.error(f"❌ 未选择设备")

# 侧边栏设置
st.sidebar.header("⚙️ 设置")

# 获取设备列表
devices = get_audio_devices()
if devices:
    device_options = list(devices.keys())
    selected_device_name = st.sidebar.selectbox(
        "选择音频输入设备",
        device_options,
        index=0
    )
    st.session_state.selected_device = devices[selected_device_name]
else:
    st.sidebar.error("未找到任何音频输入设备！")
    st.session_state.selected_device = None

# 采样率和缓冲区大小设置
st.sidebar.divider()
sample_rate = st.sidebar.slider("采样率 (Hz)", 8000, 48000, 44100, step=1000)
buffer_size = st.sidebar.slider("显示缓冲区 (ms)", 100, 5000, 1000, step=100)
buffer_samples = int(sample_rate * buffer_size / 1000)

# 界面布局
col1, col2, col3 = st.columns([1, 1, 1])

with col1:
    if st.button("🎙️ 开始录音", key="start_btn"):
        if st.session_state.selected_device is not None:
            st.session_state.is_recording = True
            st.session_state.audio_data.clear()
            thread = threading.Thread(
                target=audio_callback, 
                args=(st.session_state.selected_device,),
                daemon=True
            )
            thread.start()
            st.success("✅ 录音已启动！")
        else:
            st.error("❌ 请先选择音频设备")

with col2:
    if st.button("⏹️ 停止录音", key="stop_btn"):
        st.session_state.is_recording = False
        if st.session_state.stream:
            try:
                st.session_state.stream.stop_stream()
                st.session_state.stream.close()
            except:
                pass
        if st.session_state.p:
            try:
                st.session_state.p.terminate()
            except:
                pass
        st.info("⏸️ 录音已停止！")

with col3:
    if st.button("🗑️ 清除数据", key="clear_btn"):
        st.session_state.audio_data.clear()
        st.info("🧹 数据已清除！")

st.divider()

# 动态波形显示区域
st.subheader("📊 实时波形显示")

# 创建波形图表的占位符
waveform_placeholder = st.empty()
stats_placeholder = st.empty()

# 显示波形
if st.session_state.is_recording:
    # 使用占位符实时更新波形
    while st.session_state.is_recording and len(st.session_state.audio_data) > buffer_samples:
        with waveform_placeholder.container():
            fig, ax = plt.subplots(figsize=(14, 4))
            audio_array = np.array(list(st.session_state.audio_data)[-buffer_samples:])
            time_axis = np.arange(len(audio_array)) / sample_rate
            ax.plot(time_axis, audio_array, linewidth=0.8, color='cyan', label='波形')
            ax.set_xlabel("时间 (秒)", fontsize=11)
            ax.set_ylabel("振幅", fontsize=11)
            ax.set_title(f"麦克风音频波形 - 设备: {selected_device_name}", fontsize=12, fontweight='bold')
            ax.grid(True, alpha=0.3)
            ax.set_ylim(-1, 1)
            ax.legend(loc='upper right')
            plt.tight_layout()
            st.pyplot(fig)
        
        with stats_placeholder.container():
            col1, col2, col3, col4 = st.columns(4)
            with col1:
                st.metric("采样率", f"{sample_rate} Hz")
            with col2:
                st.metric("音频长度", f"{len(st.session_state.audio_data) / sample_rate:.2f} 秒")
            with col3:
                st.metric("最大振幅", f"{np.max(np.abs(audio_array)):.3f}")
            with col4:
                rms = np.sqrt(np.mean(audio_array**2))
                st.metric("RMS 能量", f"{rms:.3f}")
        
        time.sleep(0.5)
else:
    if len(st.session_state.audio_data) > 0:
        fig, ax = plt.subplots(figsize=(14, 4))
        audio_array = np.array(list(st.session_state.audio_data)[-buffer_samples:])
        time_axis = np.arange(len(audio_array)) / sample_rate
        ax.plot(time_axis, audio_array, linewidth=0.8, color='cyan', label='波形')
        ax.set_xlabel("时间 (秒)", fontsize=11)
        ax.set_ylabel("振幅", fontsize=11)
        ax.set_title(f"麦克风音频波形 - 设备: {selected_device_name}", fontsize=12, fontweight='bold')
        ax.grid(True, alpha=0.3)
        ax.set_ylim(-1, 1)
        ax.legend(loc='upper right')
        plt.tight_layout()
        waveform_placeholder.pyplot(fig)
        
        with stats_placeholder.container():
            col1, col2, col3, col4 = st.columns(4)
            with col1:
                st.metric("采样率", f"{sample_rate} Hz")
            with col2:
                st.metric("音频长度", f"{len(st.session_state.audio_data) / sample_rate:.2f} 秒")
            with col3:
                st.metric("最大振幅", f"{np.max(np.abs(audio_array)):.3f}")
            with col4:
                rms = np.sqrt(np.mean(audio_array**2))
                st.metric("RMS 能量", f"{rms:.3f}")
    else:
        waveform_placeholder.info("⏳ 点击「开始录音」开始采集音频...")

# 状态指示
st.divider()
col1, col2, col3 = st.columns(3)

with col1:
    if st.session_state.is_recording:
        st.success("🔴 **正在录音中...**")
    else:
        st.warning("⭕ **未录音**")

with col2:
    st.info(f"📦 缓存数据: {len(st.session_state.audio_data)}/{buffer_samples} 样本")

with col3:
    if st.session_state.selected_device is not None:
        st.success(f"✅ 设备已选择")
    else:
        st.error(f"❌ 未选择设备")
