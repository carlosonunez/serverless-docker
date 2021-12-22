#!/usr/bin/env bash
#vi: set ft=bash:
if test -e "$(dirname "$0")/.env"
then
  # Quoting this will break it.
  # shellcheck  disable=SC2046
  export $(grep -Ev '^#' "$(dirname "$0")/.env" | xargs -0)
fi

GITHUB_PROJECT="${GITHUB_PROJECT?Please provide the GitHub project to which this image is associated.}"
PROJECT="${PROJECT:-$(echo "$GITHUB_PROJECT" | cut -f2 -d '/')}"
DOCKER_HUB_USERNAME="${DOCKER_HUB_USERNAME?Please provide the username to Docker Hub.}"
DOCKER_HUB_PASSWORD="${DOCKER_HUB_PASSWORD?Please provide the password to Docker Hub.}"
DOCKER_HUB_REPO="${DOCKER_HUB_REPO:-$DOCKER_HUB_USERNAME}/$PROJECT"
REBUILD="${REBUILD:-false}"
MIN_MAJOR_VERSION=2
MIN_MINOR_VERSION=0
MIN_PATCH_VERSION=0

log_into_docker_hub_or_fail() {
  if ! docker login -u "$DOCKER_HUB_USERNAME" -p "$DOCKER_HUB_PASSWORD" >/dev/null
  then
    >&2 echo "ERROR: Unable to log into Docker Hub; see logs for more details."
    exit 1
  fi
}

get_versions_on_github() {
  page=1
  tags=""
  unsupported_tags=""
  base_uri="https://api.github.com/repos/$GITHUB_PROJECT/tags?per_page=100"
  >&2 echo "===> Getting supported versions for $GITHUB_PROJECT on Github..."
  while true
  do
    uri="$base_uri"
    test "$page" -gt 1 && uri="${uri}&page=$page"
    these_tags="$(curl -sL "$uri" | jq -r .[].name)"
    test -z "$these_tags" && break
    while read -r tag
    do
      if ! version_is_supported "$tag"
      then
        unsupported_tags="$unsupported_tags,$tag"
      else
        tags="$tags,$tag"
      fi
    done <<< "$these_tags"
    page="$((page+1))"
  done
  >&2 echo "=====> Tags to build: $tags"
  >&2 echo "=====> Unsupported tags: $unsupported_tags"
  tr ',' '\n' <<< "$(echo "$tags" | sed 's/^,//' | sed 's/,$//')"
}

get_versions() {
  get_versions_on_github
}

version_is_supported() {
  _remove_beginning_v_and_alpha_beta_tags() {
    # Eh, no.
    # shellcheck disable=SC2001
    sed -E 's/^v([0-9]{1,}\.[0-9]{1,}\.[0-9]{1,}).*$/\1/' <<< "$1"
  }
  version="$(_remove_beginning_v_and_alpha_beta_tags "$1")"
  major=$(echo "$version" | cut -f1 -d .)
  minor=$(echo "$version" | cut -f2 -d .)
  patch=$(echo "$version" | cut -f3 -d .)
  test "$major" -gt "$MIN_MAJOR_VERSION" ||
    { test "$major" -eq "$MIN_MAJOR_VERSION" &&
      test "$minor" -gt "$MIN_MINOR_VERSION"; } ||
    { test "$major" -eq "$MIN_MAJOR_VERSION" &&
      test "$minor" -eq "$MIN_MINOR_VERSION" &&
      test "$patch" -ge "$MIN_PATCH_VERSION" ; }
}

get_existing_docker_image_tags() {
  curl -s "https://registry.hub.docker.com/v2/repositories/$DOCKER_HUB_REPO/tags?page_size=10000" | \
    jq -r '.results[] | select(.name | contains("-") | not) | .name'
}

image_already_exists() {
  if grep -Eiq '^true$' <<< "$REBUILD"
  then
    >&2 echo "INFO: Skipping existing image check, as REBUILD=true"
    return 1
  fi
  grep -q "$1" <<< "$2"
}

build_and_push_new_image() {
  _build() {
    docker build -t "$image_name" \
      --pull \
      --platform "$arch" \
      --build-arg VERSION="$version" \
      --build-arg ARCH="$(echo "$arch" | cut -f2 -d '/')" .
  }

  _push() {
    docker push "$image_name"
  }

  _push_linked_manifest() {
    version="$1"
    is_latest="${2:-false}"
    version_tag="${DOCKER_HUB_REPO}:$version"
    if grep -Eiq '^true$' <<< "$is_latest"
    then
      unified_tag="$DOCKER_HUB_REPO:latest"
    else
      unified_tag="$version_tag"
    fi
    docker manifest create "$unified_tag" \
      --amend "${version_tag}-amd64" \
      --amend "${version_tag}-arm64" &&
    docker manifest push "$unified_tag"
  }

  version="$1"
  is_latest="${2:-false}"
  if test "$is_latest" == "true"
  then
    >&2 echo "INFO: Tagging $PROJECT version [$version] as latest"
    image_name="$DOCKER_HUB_REPO:latest"
    docker tag "$DOCKER_HUB_REPO:$version" "$image_name" && \
      _push_linked_manifest "$version" "$is_latest"
    return 0
  fi
  for arch in linux/arm64 linux/amd64
  do
    image_name="$DOCKER_HUB_REPO:${version}-$(echo "$arch" | cut -f2 -d '/')"
    >&2 echo "INFO: Building $PROJECT $version $arch"
    if ! ( _build && _push )
    then
      >&2 echo "ERROR: Failed to build and push version $version; stopping"
      exit 1
    fi
  done

  test "$is_latest" == "true" || _push_linked_manifest "$version"
}

>&2 echo "===> Creating Docker images for $GITHUB_PROJECT"
log_into_docker_hub_or_fail
existing_tags=$(get_existing_docker_image_tags)
versions_needing_an_image=""
first_image_in_list=true
latest_version=""
while read -r version
do
  if test "$first_image_in_list" == "true"
  then
    >&2 echo "INFO: Latest $PROJECT version is $version"
    latest_version="$version"
    first_image_in_list=false
  fi
  if ! image_already_exists "$version" "$existing_tags"
  then
    if test "$1" == "--alert-only"
    then
      versions_needing_an_image="$versions_needing_an_image,$version"
    else
      build_and_push_new_image "$version"
    fi
  else
    >&2 echo "INFO: Docker image already exists for $PROJECT v$version"
  fi
done <<< "$(get_versions)"
build_and_push_new_image "$latest_version" "true"

# GitHub Actions doesn't support ARM runners, and spinning one up in AWS that does nothing
# is a waste of money. Instead, alert me when a new version comes out so I can run this script.
if ! test -z "$versions_needing_an_image"
then
  versions_fixed=$(echo "$versions_needing_an_image" | sed 's/^,//; s/,/, /g')
  >&2 echo "INFO: Build Docker images for these $PROJECT versions: [$versions_fixed]"
  exit 1
fi
