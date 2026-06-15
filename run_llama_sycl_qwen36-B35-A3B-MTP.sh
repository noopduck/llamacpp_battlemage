#!/bin/bash

source /opt/intel/oneapi/setvars.sh --force

bin/llama-server \
  -m /home/$USER/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF/snapshots/a483e9e6cbd595906af30beda3187c2663a1118c/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf \
  -ngl 99 \
  --flash-attn on \
  --batch-size 4096 \
  --ubatch-size 1024 \
  --host 0.0.0.0 \
  --port 11434

