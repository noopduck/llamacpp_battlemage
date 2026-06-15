#!/bin/bash

source /opt/intel/oneapi/setvars.sh --force

bin/llama-server \
  -hf unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q4_K_M \
  -ngl 99 \
  --flash-attn on \
  --batch-size 4096 \
  --ubatch-size 1024 \
  --host 0.0.0.0 \
  --port 11434

