#! /bin/bash
set -e

usage() {
    printf "Usage: $0 [--no-check|-n]"
}

NO_CHECK=0
while getopts ":n" opt; do
    case $opt in
        n)
            NO_CHECK=1
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            exit 1
            ;;
    esac
done


BUILDER_NAME=dstack-build
THIS_DIR=$(cd $(dirname $0); pwd)
REPO_ROOT=$(dirname $THIS_DIR)
GIT_DIR=$REPO_ROOT

HOST_BUILD_DIR_A=${THIS_DIR}/build-a
HOST_BUILD_DIR_B=${THIS_DIR}/build-b

# guest dirs
GUEST_BUILD_DIR=/dstack-build
GUEST_SRC_DIR=/meta-dstack

cd $THIS_DIR

mkdir -p .dummy
(cd .dummy && docker build -t $BUILDER_NAME -f ../Dockerfile.repro .)
rm -rf .dummy

build_to() {
    mkdir -p $1
    BUILD_CMD="${2} ${GUEST_SRC_DIR}/build.sh guest ./bb-build"
    docker run --rm \
        --user $(id -u):$(id -g) \
        -v $REPO_ROOT:$GUEST_SRC_DIR \
        -v $1:$GUEST_BUILD_DIR \
        -w $GUEST_BUILD_DIR \
        $BUILDER_NAME bash -e -c "$BUILD_CMD"
}

build_to $HOST_BUILD_DIR_A DSTACK_TAR_RELEASE=1
mv $HOST_BUILD_DIR_A/images/*.tar.gz .
if [ $NO_CHECK -eq 0 ]; then
    build_to $HOST_BUILD_DIR_B
    ${THIS_DIR}/check.sh $HOST_BUILD_DIR_A $HOST_BUILD_DIR_B
fi

if [[ -n $(git -C $GIT_DIR status --porcelain) ]]; then
    echo "The working tree is not clean, skip generating reproducible build command"
    exit 0
fi

echo "## Reproducible build command:"
echo '```bash'
echo "git clone https://github.com/Dstack-TEE/meta-dstack.git --recursive"
echo "cd meta-dstack/repro-build"
echo "git checkout $(git -C $GIT_DIR rev-parse HEAD)"
echo "./repro-build.sh --no-check"
echo '```'
