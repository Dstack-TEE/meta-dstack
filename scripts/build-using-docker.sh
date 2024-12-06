#! /bin/bash

THIS_DIR=$(cd $(dirname $0); pwd)
REPO_ROOT=$(cd $THIS_DIR/..; pwd)

docker run --rm -it -v $REPO_ROOT:/dstack -w /dstack ubuntu:24.04 bash -c "./scripts/build-in-docker.sh"
