#!/usr/bin/env bash
#
# build-images.sh — build and push the writer + reviewer agent images to ECR, so install.sh needs no
# pre-built images and no local Docker.
#
# The tag is a hash of agents/writer-agent/ + agents/reviewer-agent/, so:
#   * an unchanged source tree is never rebuilt (re-running install.sh is fast), and
#   * a changed agent.py always produces a new tag, so the Deployments roll instead of silently
#     running a stale :latest.
#
# BUILDERS, picked in this order (override with IMAGE_BUILDER=docker|codebuild):
#   docker     `docker buildx` on this machine, if a working Docker daemon is present.
#   codebuild  an AWS CodeBuild project in the image account. No local Docker needed. The source is
#              zipped to a private S3 bucket and built on CodeBuild's managed image.
#
# OUTPUT: the last two lines on stdout are machine-readable, everything else goes to stderr:
#   WRITER_IMAGE=<uri>
#   REVIEWER_IMAGE=<uri>
#
# Usage:
#   AWS_ACCOUNT_ID=123456789012 IMAGE_REGION=us-west-2 ./agents/build-images.sh
#   ./agents/build-images.sh --teardown    # delete the ECR repos, bucket, CodeBuild project + role
#
# Config (env):
#   AWS_ACCOUNT_ID     account that owns the ECR repos               (default: from `aws sts`)
#   IMAGE_REGION       region for ECR / S3 / CodeBuild                 (default: AWS_REGION, else us-east-1)
#   IMAGE_REPO_PREFIX  ECR repo prefix                                 (default: agentgateway-egress)
#   IMAGE_PLATFORM     target platform                                 (default: linux/amd64)
#   IMAGE_BUILDER      docker | codebuild                              (default: auto)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS=(writer-agent reviewer-agent)

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
IMAGE_REGION="${IMAGE_REGION:-${AWS_REGION:-us-east-1}}"
IMAGE_REPO_PREFIX="${IMAGE_REPO_PREFIX:-agentgateway-egress}"
IMAGE_PLATFORM="${IMAGE_PLATFORM:-linux/amd64}"
IMAGE_BUILDER="${IMAGE_BUILDER:-}"
CODEBUILD_PROJECT="${IMAGE_REPO_PREFIX}-agent-images"
CODEBUILD_ROLE="${IMAGE_REPO_PREFIX}-codebuild"

# Everything human-readable goes to stderr so stdout carries only the WRITER_IMAGE/REVIEWER_IMAGE lines.
info() { printf '\033[1;34m----\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m OK \033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

resolve() {
  command -v aws >/dev/null 2>&1 || die "aws CLI not found on PATH"
  [ -n "$AWS_ACCOUNT_ID" ] || AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "AWS_ACCOUNT_ID='$AWS_ACCOUNT_ID' is not 12 digits"
  REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${IMAGE_REGION}.amazonaws.com"
  BUCKET="${IMAGE_REPO_PREFIX}-build-${AWS_ACCOUNT_ID}-${IMAGE_REGION}"
  # Content hash of both agent directories (paths + bytes), sorted so it is stable across machines.
  TAG="$(cd "$SCRIPT_DIR" && find "${AGENTS[@]}" -type f ! -name '.*' ! -path '*/__pycache__/*' | LC_ALL=C sort \
    | while read -r f; do printf '%s\n' "$f"; cat "$f"; done | shasum -a 256 | cut -c1-12)"
}

image_uri() { printf '%s/%s/%s:%s' "$REGISTRY" "$IMAGE_REPO_PREFIX" "$1" "$TAG"; }

image_exists() {
  aws ecr describe-images --region "$IMAGE_REGION" --repository-name "${IMAGE_REPO_PREFIX}/$1" \
    --image-ids imageTag="$TAG" >/dev/null 2>&1
}

ensure_repos() {
  local a
  for a in "${AGENTS[@]}"; do
    aws ecr describe-repositories --region "$IMAGE_REGION" --repository-names "${IMAGE_REPO_PREFIX}/$a" >/dev/null 2>&1 \
      || { aws ecr create-repository --region "$IMAGE_REGION" --repository-name "${IMAGE_REPO_PREFIX}/$a" \
             --image-scanning-configuration scanOnPush=true >/dev/null
           ok "created ECR repo ${IMAGE_REPO_PREFIX}/$a"; }
  done
}

pick_builder() {
  if [ -n "$IMAGE_BUILDER" ]; then
    case "$IMAGE_BUILDER" in docker|codebuild) return 0 ;; *) die "IMAGE_BUILDER must be docker or codebuild" ;; esac
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
    IMAGE_BUILDER=docker
  else
    IMAGE_BUILDER=codebuild
  fi
}

build_docker() {
  info "building with local docker buildx ($IMAGE_PLATFORM)"
  aws ecr get-login-password --region "$IMAGE_REGION" \
    | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
  local a
  for a in "${AGENTS[@]}"; do
    docker buildx build --platform "$IMAGE_PLATFORM" --push -t "$(image_uri "$a")" "$SCRIPT_DIR/$a" >&2
    ok "pushed $(image_uri "$a")"
  done
}

# The buildspec is static; everything that varies arrives as environment-variable overrides.
BUILDSPEC='version: 0.2
phases:
  pre_build:
    commands:
      - aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"
  build:
    commands:
      - |
        for a in writer-agent reviewer-agent; do
          docker build --platform "$IMAGE_PLATFORM" -t "$REGISTRY/$IMAGE_REPO_PREFIX/$a:$TAG" "$a"
          docker push "$REGISTRY/$IMAGE_REPO_PREFIX/$a:$TAG"
        done'

ensure_codebuild() {
  if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    if [ "$IMAGE_REGION" = us-east-1 ]; then
      aws s3api create-bucket --bucket "$BUCKET" --region "$IMAGE_REGION" >/dev/null
    else
      aws s3api create-bucket --bucket "$BUCKET" --region "$IMAGE_REGION" \
        --create-bucket-configuration LocationConstraint="$IMAGE_REGION" >/dev/null
    fi
    ok "created build-source bucket s3://$BUCKET"
  fi
  # Source zips only — never public.
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  local trust policy
  trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  policy="$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":"arn:aws:logs:${IMAGE_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/codebuild/${CODEBUILD_PROJECT}*"},
 {"Effect":"Allow","Action":["s3:GetObject","s3:GetObjectVersion"],"Resource":"arn:aws:s3:::${BUCKET}/*"},
 {"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart",
   "ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer"],
  "Resource":["arn:aws:ecr:${IMAGE_REGION}:${AWS_ACCOUNT_ID}:repository/${IMAGE_REPO_PREFIX}/writer-agent",
              "arn:aws:ecr:${IMAGE_REGION}:${AWS_ACCOUNT_ID}:repository/${IMAGE_REPO_PREFIX}/reviewer-agent"]}]}
EOF
)"
  local new_role=""
  if ! aws iam get-role --role-name "$CODEBUILD_ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$CODEBUILD_ROLE" --assume-role-policy-document "$trust" \
      --description "agentgateway egress: builds the agent images" >/dev/null
    new_role=1
    ok "created role $CODEBUILD_ROLE"
  fi
  aws iam put-role-policy --role-name "$CODEBUILD_ROLE" --policy-name build --policy-document "$policy"

  if ! aws codebuild batch-get-projects --region "$IMAGE_REGION" --names "$CODEBUILD_PROJECT" \
         --query 'projects[0].name' --output text 2>/dev/null | grep -qx "$CODEBUILD_PROJECT"; then
    # A brand-new role is not assumable by CodeBuild for several seconds; create-project validates it.
    for _ in 1 2 3 4 5 6; do
      if aws codebuild create-project --region "$IMAGE_REGION" --name "$CODEBUILD_PROJECT" \
           --source "type=S3,location=${BUCKET}/agent-images/src.zip" \
           --artifacts type=NO_ARTIFACTS \
           --environment "type=LINUX_CONTAINER,image=aws/codebuild/amazonlinux2-x86_64-standard:5.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true" \
           --service-role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CODEBUILD_ROLE}" >/dev/null 2>&1; then
        ok "created CodeBuild project $CODEBUILD_PROJECT"; return 0
      fi
      [ -n "$new_role" ] || break
      sleep 10
    done
    die "could not create CodeBuild project $CODEBUILD_PROJECT"
  fi
}

build_codebuild() {
  case "$IMAGE_PLATFORM" in
    linux/amd64) ;;
    *) die "the CodeBuild builder only builds linux/amd64 (got IMAGE_PLATFORM=$IMAGE_PLATFORM); use IMAGE_BUILDER=docker" ;;
  esac
  info "building with AWS CodeBuild ($CODEBUILD_PROJECT in $IMAGE_REGION)"
  ensure_codebuild
  local work; work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN
  cp -R "${AGENTS[@]/#/$SCRIPT_DIR/}" "$work/"
  printf '%s\n' "$BUILDSPEC" > "$work/buildspec.yml"
  (cd "$work" && zip -qr src.zip "${AGENTS[@]}" buildspec.yml)
  aws s3 cp "$work/src.zip" "s3://${BUCKET}/agent-images/src.zip" --quiet

  local id status
  id="$(aws codebuild start-build --region "$IMAGE_REGION" --project-name "$CODEBUILD_PROJECT" \
    --environment-variables-override \
      "name=REGISTRY,value=${REGISTRY}" "name=IMAGE_REPO_PREFIX,value=${IMAGE_REPO_PREFIX}" \
      "name=TAG,value=${TAG}" "name=IMAGE_PLATFORM,value=${IMAGE_PLATFORM}" \
    --query build.id --output text)"
  info "waiting for build $id (typically 2-4 minutes)"
  while :; do
    status="$(aws codebuild batch-get-builds --region "$IMAGE_REGION" --ids "$id" \
      --query 'builds[0].buildStatus' --output text)"
    [ "$status" = IN_PROGRESS ] || break
    sleep 15
  done
  if [ "$status" != SUCCEEDED ]; then
    local link
    link="$(aws codebuild batch-get-builds --region "$IMAGE_REGION" --ids "$id" \
      --query 'builds[0].logs.deepLink' --output text 2>/dev/null || true)"
    die "CodeBuild build $id finished $status. Logs: ${link:-see the CodeBuild console}"
  fi
  ok "CodeBuild pushed both images (tag $TAG)"
}

build() {
  resolve
  ensure_repos
  local a missing=0
  for a in "${AGENTS[@]}"; do image_exists "$a" || missing=1; done
  if [ "$missing" -eq 0 ]; then
    ok "images for source hash $TAG already in ECR — skipping build"
  else
    pick_builder
    "build_${IMAGE_BUILDER}"
    for a in "${AGENTS[@]}"; do image_exists "$a" || die "$(image_uri "$a") is not in ECR after the build"; done
  fi
  echo "WRITER_IMAGE=$(image_uri writer-agent)"
  echo "REVIEWER_IMAGE=$(image_uri reviewer-agent)"
}

teardown() {
  resolve
  warn "deleting agent image build resources in ${AWS_ACCOUNT_ID}/${IMAGE_REGION}"
  local a
  for a in "${AGENTS[@]}"; do
    aws ecr delete-repository --region "$IMAGE_REGION" --repository-name "${IMAGE_REPO_PREFIX}/$a" --force >/dev/null 2>&1 \
      && ok "deleted ECR repo ${IMAGE_REPO_PREFIX}/$a" || true
  done
  aws codebuild delete-project --region "$IMAGE_REGION" --name "$CODEBUILD_PROJECT" >/dev/null 2>&1 \
    && ok "deleted CodeBuild project $CODEBUILD_PROJECT" || true
  aws iam delete-role-policy --role-name "$CODEBUILD_ROLE" --policy-name build >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$CODEBUILD_ROLE" >/dev/null 2>&1 && ok "deleted role $CODEBUILD_ROLE" || true
  if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    aws s3 rm "s3://$BUCKET" --recursive --quiet || true
    aws s3api delete-bucket --bucket "$BUCKET" --region "$IMAGE_REGION" && ok "deleted bucket s3://$BUCKET"
  fi
}

case "${1:-build}" in
  build)      build ;;
  --teardown) teardown ;;
  *)          die "unknown argument '$1'. Use: build | --teardown" ;;
esac
