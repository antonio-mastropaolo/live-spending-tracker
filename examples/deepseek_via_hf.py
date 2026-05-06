#!/usr/bin/env python3
"""
Use DeepSeek-V4-Pro via the HuggingFace Inference Router, routed through
the local spend-tracker proxy so costs are captured automatically.

Requirements:
  pip install openai
  export HF_TOKEN=hf_...
  export HF_BASE_URL=http://localhost:7778/huggingface   # set by install.sh

Usage:
  python3 examples/deepseek_via_hf.py
"""
import os
from openai import OpenAI

client = OpenAI(
    base_url=os.environ.get("HF_BASE_URL", "http://localhost:7778/huggingface") + "/v1",
    api_key=os.environ["HF_TOKEN"],
)

response = client.chat.completions.create(
    model="deepseek-ai/DeepSeek-V4-Pro",
    messages=[{"role": "user", "content": "What is 2 + 2? Answer briefly."}],
    max_tokens=64,
)

print(response.choices[0].message.content)
print(f"\nUsage: {response.usage}")
