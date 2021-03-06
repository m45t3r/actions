#!/bin/bash

_requires_token() {
  if [[ -z $GITHUB_TOKEN ]]; then
    echo "Set the GITHUB_TOKEN env variable."
    exit 1
  fi
}

_should_fix_issue() {
  pr_url="$(jq --raw-output '.issue.pull_request.url | select(. != null)' "$GITHUB_EVENT_PATH")"
  fix_comment="$(jq --raw-output ".comment.body | select(. | startswith(\"$1\"))" "$GITHUB_EVENT_PATH")"
  [[ -n $pr_url ]] && [[ -n $fix_comment ]] || exit 0
}

_should_fix_review() {
  fix_comment="$(jq --raw-output ".review.body | select(. | startswith(\"$1\"))" "$GITHUB_EVENT_PATH")"
  [[ -n $fix_comment ]] || exit 0
}

_git_is_dirty() {
  [[ -n "$(git status -s)" ]]
}

_local_commit() {
  git config --global user.name "github-actions[bot]"
  git config --global user.email "github-actions[bot]@users.noreply.github.com"
  git add .
  git commit -m "${GITHUB_ACTION}: lint fix"
}

_remote_commit() {
  tmp_file="$(mktemp)"

  # shellcheck disable=SC2034  # Unused variables left for readability
  while read -r _src_mode dst_mode _src_sha dst_sha flag path; do
    file_payload="{\"encoding\": \"base64\", \"content\": \"$(base64 "$path" | tr -d '\n')\"}"
    file_response=$(curl --fail -H "Authorization: token ${GITHUB_TOKEN}" \
      -d "$file_payload" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/git/blobs")
    echo "{ \"mode\": \"${dst_mode}\", \"path\": \"${path}\", \"sha\": $(jq '.sha' <<<"$file_response")}" >>"$tmp_file"
  done < <(git diff-files)

  head_response="$(curl --fail -H "Authorization: token ${GITHUB_TOKEN}" \
    -X GET \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/git/${GITHUB_REF}")"
  head_sha="$(jq '.object.sha' <<<"$head_response")"

  tree_payload="{\"base_tree\": ${head_sha}, \"tree\": $(jq -s '.' "$tmp_file")}"
  tree_response="$(curl --fail -H "Authorization: token ${GITHUB_TOKEN}" \
    -d "$tree_payload" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/git/trees")"

  commit_payload="{\"message\": \"${GITHUB_ACTION}: lint fix\", \"tree\": $(jq '.sha' <<<"$tree_response"), \"parents\": [${head_sha}]}"
  commit_response="$(curl --fail -H "Authorization: token ${GITHUB_TOKEN}" \
    -d "$commit_payload" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/git/commits")"

  update_branch_payload="{\"sha\": $(jq '.sha' <<<"$commit_response")}"
  # shellcheck disable=SC2034  # Unused variables left for readability
  update_branch_response="$(curl --fail -H "Authorization: token ${GITHUB_TOKEN}" \
    -d "$update_branch_payload" \
    -X PATCH \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/git/${GITHUB_REF}")"
}

_commit_if_needed() {
  if _git_is_dirty; then
    _remote_commit
    _local_commit
  fi
}

_lint_and_fix_action() {
  if [[ $GITHUB_EVENT_NAME == "push" ]]; then
    if [[ ${2:-} == "autofix" ]]; then
      _requires_token
      fix
      _commit_if_needed
      lint
    else
      lint
    fi
  elif [[ $GITHUB_EVENT_NAME == "pull_request_review" ]]; then
    _requires_token
    _should_fix_review "fix $GITHUB_ACTION" || _should_fix_review "fix $1"
    fix
    _commit_if_needed
  fi
}
