from openai import OpenAI
 
client = OpenAI(
    base_url="http://localhost:8010/v1",
    api_key="EMPTY"
)
 
result = client.chat.completions.create(
    model="gpt-oss-20b",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Explain what MXFP4 quantization is."}
    ]
)
 
print(result.choices[0].message.content)