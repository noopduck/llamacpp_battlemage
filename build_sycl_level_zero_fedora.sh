#!/bin/bash

sudo dnf install cmake ninja-build pkg-config
git clone https://github.com/oneapi-src/level-zero ~/level-zero-loader
cd ~/level-zero-loader
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build -j$(nproc)
sudo cmake --install build
sudo ldconfig
sycl-ls
