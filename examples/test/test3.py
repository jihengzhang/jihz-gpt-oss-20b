#!/usr/bin/env python3
"""
Remote GPT-OSS-20B API Client Test (Streaming Mode)

This script allows accessing the vLLM server from another machine with streaming output.
Update SERVER_HOST to the IP address or hostname of the machine running vLLM.

Usage:
    python test2.py
    
Example with custom server:
    Change SERVER_HOST = "192.168.0.115" to your server's IP address
"""

from openai import OpenAI

# Configure the remote server address
# Change this to the IP address or hostname of the machine running vLLM
SERVER_HOST = "192.168.0.113"  # Replace with your server IP
SERVER_PORT = 8010

# Create client with remote server URL
client = OpenAI(
    base_url=f"http://{SERVER_HOST}:{SERVER_PORT}/v1",
    api_key="EMPTY"
)

# Make streaming API call to remote vLLM server
print("Response from remote GPT-OSS-20B (streaming):")
print("-" * 50)

stream = client.chat.completions.create(
    model="gpt-oss-20b",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "用中文解释：In area of LLM, Explain what MXFP4 quantization is."}
    ],
    stream=True  # 启用流式输出
)

# 实时输出每个token
for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)

print("\n" + "-" * 50)
print("✓ Streaming response completed")

