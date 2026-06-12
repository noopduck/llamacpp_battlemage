Setup for Intel Arc B70 Battlemage on Fedora 44

We need to add oneAPI repo from intel and install some dependencies
Then we must build the level-zero driver for Fedora since intel doesnt ship it as Fedora packages
When this is done we must test to see that sycl can see the card like so:

[shell@heracles]~% source /opt/intel/oneapi/setvars.sh

[shell@heracles]~% sycl-ls
[level_zero:gpu][level_zero:0] Intel(R) oneAPI Unified Runtime over Level-Zero V2, Intel(R) Arc(TM) Pro B70 Graphics 20.2.0 [1.15.38308+1]
[opencl:cpu][opencl:0] Intel(R) OpenCL, AMD Ryzen 9 5900X 12-Core Processor             OpenCL 3.0 (Build 0) [2026.21.3.0.31_160000]
[opencl:gpu][opencl:1] Intel(R) OpenCL Graphics, Intel(R) Arc(TM) Pro B70 Graphics OpenCL 3.0 NEO  [26.18.38308.1]

Identifying the card means we can proceed by building llama.cpp with sycl support which enables XMX and makes LLM processing amazing and splendid 70ish tokens on the Qwen 3.6 35B A3B... just saying

Run the scripts in this order to set everything up, at this point in time the script is based on my notes and
something may not be correct, please create an issue if something fails.

At least i can attest that llama build works and runs on the SYCL backend on my computer.

setup_oneapi_and_other_reqs.sh
build_llamacpp_sycl.sh

Choose a model to run or customize your own run script with the model you would like

Have fun <3

