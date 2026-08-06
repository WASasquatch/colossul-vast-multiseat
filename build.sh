#!/usr/bin/env bash
# Build and (optionally) push the Colossul multi-seat image.
#
#   ./build.sh                              # build :dev locally
#   ./build.sh -t myorg/colossul:1.0 --push
#   BASE_IMAGE=vastai/comfy:<tag> ./build.sh
#
# Vast.ai hosts run linux/amd64, so the platform is pinned rather than
# inherited from the machine you happen to build on (an arm64 Mac would
# otherwise produce an image no host can run).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

TAG="${TAG:-colossul/multiseat:dev}"
BASE_IMAGE="${BASE_IMAGE:-vastai/comfy:v0.30.0-cuda-13.2-py312}"
PLATFORM="${PLATFORM:-linux/amd64}"
PUSH=0

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--tag)  TAG="$2"; shift 2 ;;
        --base)    BASE_IMAGE="$2"; shift 2 ;;
        --push)    PUSH=1; shift ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)         echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

echo "Building $TAG"
echo "  base     : $BASE_IMAGE"
echo "  platform : $PLATFORM"
echo ""

args=(build --platform "$PLATFORM" --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$TAG" .)
[ "$PUSH" = "1" ] && args+=(--push)

if docker buildx version >/dev/null 2>&1; then
    docker buildx "${args[@]}"
else
    # Plain builder can't --push inline; fall back to build-then-push.
    docker build --platform "$PLATFORM" --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$TAG" .
    [ "$PUSH" = "1" ] && docker push "$TAG"
fi

echo ""
echo "Done: $TAG"
[ "$PUSH" = "1" ] || echo "Not pushed. Re-run with --push (Vast hosts must be able to pull it)."
