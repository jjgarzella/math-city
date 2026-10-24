#!/usr/bin/env bash
# Shared review-target grammar used by the resolver and analyze provenance.
# Source this file, then call review_target_classify <target> [work_dir]. The
# result is exposed in REVIEW_TARGET_KIND and, for ranges, the parsed endpoints.
review_target_classify() {
  local target="${1-}" work_dir="${2:-$PWD}"

  REVIEW_TARGET_KIND=""
  REVIEW_TARGET_RANGE_BASE_REF=""
  REVIEW_TARGET_RANGE_HEAD_REF=""
  REVIEW_TARGET_RANGE_SEPARATOR=""

  if [[ "$target" =~ ^#?[0-9]+$ ]] || [[ "$target" =~ ^https?://.*/pull/[0-9]+/?$ ]]; then
    REVIEW_TARGET_KIND=pr
  else
    case "$target" in
      "."|".."|"./"*|"../"*|"/"*)
        REVIEW_TARGET_KIND=path
        return 0
        ;;
    esac

    if [[ "$target" == *..* ]]; then
      REVIEW_TARGET_KIND=range
      if [[ "$target" == *...* ]]; then
        REVIEW_TARGET_RANGE_BASE_REF="${target%%...*}"
        REVIEW_TARGET_RANGE_HEAD_REF="${target#*...}"
        REVIEW_TARGET_RANGE_SEPARATOR="..."
      else
        REVIEW_TARGET_RANGE_BASE_REF="${target%%..*}"
        REVIEW_TARGET_RANGE_HEAD_REF="${target#*..}"
        REVIEW_TARGET_RANGE_SEPARATOR=".."
      fi
    elif [ -e "$work_dir/$target" ]; then
      REVIEW_TARGET_KIND=path
    else
      REVIEW_TARGET_KIND=branch
    fi
  fi
}
