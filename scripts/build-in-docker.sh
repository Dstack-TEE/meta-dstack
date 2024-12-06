#! /bin/bash

set -e

apt update
apt install -y build-essential chrpath diffstat lz4 wireguard-tools mkisofs python3

mkdir -p docker-build
cd docker-build
source ../dev-setup
../build.sh guest
