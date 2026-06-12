#!/bin/bash

source /opt/intel/oneapi/setvars.sh --force

bin/llama-server \
  -m /home/$USER/.cache/huggingface/hub/models--unsloth--gemma-4-26B-A4B-it-GGUF/snapshots/3bb10d594514ef4edb7f3a65d41a7e4eb8c5767a/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf \
  -ngl 99 \
  --flash-attn on \
  --host 0.0.0.0 \
  --port 11434

