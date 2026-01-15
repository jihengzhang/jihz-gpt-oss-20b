from openai import OpenAI
 
client = OpenAI(
    base_url="http://localhost:8010/v1",
    api_key="EMPTY"
)
 
result = client.chat.completions.create(
    model="gpt-oss-20b",
    messages=[
        {"role": "system", "content": "You are a helpful technical assistant. Provide concise, accurate explanations."},
        {"role": "user", "content": "In the context of LLM (Large Language Model) inference optimization, explain MXFP4 quantization in 2-3 sentences."}
    ]
)
 
print(result.choices[0].message.content)