
if [ -z "$IMAGE" ]
then
  IMAGE=${CI_PROJECT_PATH/docker/tgbyte}
fi

if [ -z "$TAG" ]
then
  case ${CI_BUILD_REF_NAME} in
  master)
    TAG="latest"
    ;;
  *)
    TAG=${CI_BUILD_REF_NAME//[^0-9A-Za-z_.\-]/-}
    ;;
  esac
fi

if [ -z "$ARCH" ]
then
  ARCH=$(docker version | grep OS/Arch | head -1 | sed s,.\*/,,)
fi

if [ -z "$BUILD_DIR" ]
then
  BUILD_DIR="."
fi

if [ -z "$BUILD_DIR" ]
then
  DOCKERFILE="${BUILD_DIR}/Dockerfile"
fi

FULL_IMAGE_ARCH="$IMAGE":"$TAG"-"$ARCH"
FULL_IMAGE="$IMAGE":"$TAG"

echo IMAGE: $IMAGE
echo TAG: $TAG
echo ARCH: $ARCH
echo BUILD_DIR: $BUILD_DIR
echo DOCKERFILE: $DOCKERFILE
