#!/bin/bash

source /opt/intel/oneapi/setvars.sh --force

bin/llama-server \
  -hf unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL \
  -ngl 99 \
  --flash-attn on \
  --batch-size 4096 \
  --ubatch-size 1024 \
  --host 0.0.0.0 \
  --port 11434

