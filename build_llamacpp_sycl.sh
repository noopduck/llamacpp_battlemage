#!/bin/bash

source /opt/intel/oneapi/setvars.sh

cmake . \
    -DLLAMA_SYCL=ON \
    -DLLAMA_OPENSSL=ON \
    -DCMAKE_C_COMPILER=icx \
    -DCMAKE_CXX_COMPILER=icpx \
    -DLLAMA_SYCL_F16=ON
make -j$(nproc)
