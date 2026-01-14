#!/usr/bin/env python3
"""
Remote GPT-OSS-20B API Client Test

This script allows accessing the vLLM server from another machine.
Update SERVER_HOST to the IP address or hostname of the machine running vLLM.

Usage:
    python test2.py
    
Example with custom server:
    Change SERVER_HOST = "192.168.0.114" to your server's IP address
"""

from openai import OpenAI

# Configure the remote server address
# Change this to the IP address or hostname of the machine running vLLM
SERVER_HOST = "192.168.0.115"  # Replace with your server IP
SERVER_PORT = 8010

# Create client with remote server URL
client = OpenAI(
    base_url=f"http://{SERVER_HOST}:{SERVER_PORT}/v1",
    api_key="EMPTY"
)

# Make API call to remote vLLM server
result = client.chat.completions.create(
    model="gpt-oss-20b",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Explain what MXFP4 quantization is."}
    ]
)

print("Response from remote GPT-OSS-20B:")
print(result.choices[0].message.content)
