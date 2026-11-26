#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export GIT_TERMINAL_PROMPT=0 LC_ALL=C

require_current_tag() {
    git fetch --quiet --no-tags --depth=1 origin refs/heads/push-to-github
    branch_tip=$(git rev-parse --verify FETCH_HEAD)
    if [ "$branch_tip" != "$CI_COMMIT_SHA" ]; then
        echo 'Skipping release: the tag is not at the tip of push-to-github.'
        exit 0
    fi
}

fetch_gitlab_history() {
    if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
        git fetch --quiet --tags --unshallow origin refs/heads/push-to-github 2>/dev/null ||
            git fetch --quiet --tags --depth=200 origin refs/heads/push-to-github
    else
        git fetch --quiet --tags origin refs/heads/push-to-github
    fi
}

find_sync_base() {
    github_tip=$1
    github_tree=$2
    found=''

    # 1. Prefer an explicit GitLab-Commit marker recorded in recent GitHub main commits.
    for candidate in $(git log -n 20 --format=%B "$github_tip" 2>/dev/null |
        sed -n 's/.*GitLab-Commit:[[:space:]]*`*\([0-9a-fA-F]\{40\}\).*/\1/p'); do
        if git cat-file -e "${candidate}^{commit}" 2>/dev/null &&
            git merge-base --is-ancestor "$candidate" "$CI_COMMIT_SHA" 2>/dev/null; then
            found=$candidate
            break
        fi
    done

    # 2. Match GitHub main's current tree against push-to-github commit history.
    if [ -z "$found" ] && git rev-parse --verify "${CI_COMMIT_SHA}^" >/dev/null 2>&1; then
        found=$(git log --format='%H %T' "${CI_COMMIT_SHA}^" 2>/dev/null |
            awk -v target="$github_tree" '$2 == target { print $1; exit }')
    fi

    # 3. Fallback to the nearest previous tag reachable from this commit.
    if [ -z "$found" ] && git rev-parse --verify "${CI_COMMIT_SHA}^" >/dev/null 2>&1; then
        prev_tag=$(git describe --tags --abbrev=0 "${CI_COMMIT_SHA}^" 2>/dev/null || :)
        if [ -n "$prev_tag" ]; then
            found=$(git rev-parse --verify "${prev_tag}^{commit}" 2>/dev/null || :)
        fi
    fi

    printf '%s' "$found"
}

collect_commits() {
    base_sha=$1
    fmt=$2
    if [ -n "$base_sha" ]; then
        range="${base_sha}..${CI_COMMIT_SHA}"
        count=$(git rev-list --no-merges --count "$range" 2>/dev/null || echo 0)
        if [ "$count" -gt 0 ]; then
            git log --no-merges --reverse --max-count=100 --format="$fmt" "$range"
            if [ "$count" -gt 100 ]; then
                printf '... (%s more commits omitted)\n' "$((count - 100))"
            fi
            return
        fi
        count=$(git rev-list --count "$range" 2>/dev/null || echo 0)
        if [ "$count" -gt 0 ]; then
            git log --reverse --max-count=100 --format="$fmt" "$range"
            if [ "$count" -gt 100 ]; then
                printf '... (%s more commits omitted)\n' "$((count - 100))"
            fi
            return
        fi
    fi
    git log --no-merges --reverse --max-count=30 --format="$fmt" "$CI_COMMIT_SHA"
}

json_escape_string() {
    awk '
        BEGIN { first = 1 }
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\r/, "\\r")
            gsub(/\t/, "\\t")
            if (!first) printf "\\n"
            first = 0
            printf "%s", $0
        }
    '
}

build_pr_payload() {
    title_file=$1
    head_branch=$2
    base_branch=$3
    body_file=$4
    out_file=$5
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$title_file" "$head_branch" "$base_branch" "$body_file" "$out_file" <<'PY'
import json, sys
title = open(sys.argv[1], encoding="utf-8").read().strip()
body = open(sys.argv[4], encoding="utf-8").read()
payload = {"title": title, "head": sys.argv[2], "base": sys.argv[3], "body": body}
open(sys.argv[5], "w", encoding="utf-8").write(json.dumps(payload, ensure_ascii=False))
PY
    else
        title_json=$(json_escape_string < "$title_file")
        body_json=$(json_escape_string < "$body_file")
        head_json=$(printf '%s' "$head_branch" | json_escape_string)
        base_json=$(printf '%s' "$base_branch" | json_escape_string)
        printf '{"title":"%s","head":"%s","base":"%s","body":"%s"}\n' \
            "$title_json" "$head_json" "$base_json" "$body_json" > "$out_file"
    fi
}

parse_open_pr_number() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json, sys; data = json.load(sys.stdin); print(data[0]["number"] if isinstance(data, list) and data else "")'
    else
        tr '\n' ' ' | sed -n 's/.*"number":[[:space:]]*\([0-9][0-9]*\).*/\1/p'
    fi
}

parse_pr_url() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json, sys; data = json.load(sys.stdin); print(data.get("html_url", "") if isinstance(data, dict) else "")'
    else
        tr '\n' ' ' | sed -n 's/.*"html_url":[[:space:]]*"\([^"]*\)".*/\1/p'
    fi
}

github_api_request() {
    method=$1
    url=$2
    payload_file=${3:-}
    resp_file=$4
    if [ -n "$payload_file" ]; then
        status=$(curl -sS -o "$resp_file" -w '%{http_code}' -X "$method" \
            --config "$work/curl.cfg" -H 'Content-Type: application/json' \
            --data-binary "@$payload_file" "$url")
    else
        status=$(curl -sS -o "$resp_file" -w '%{http_code}' -X "$method" \
            --config "$work/curl.cfg" "$url")
    fi
    case "$status" in
        2??) return 0 ;;
        *)
            printf 'GitHub API %s %s failed (HTTP %s):\n' "$method" "$url" "$status" >&2
            cat "$resp_file" >&2
            printf '\n' >&2
            return 1
            ;;
    esac
}

: "${CI_COMMIT_TAG:?a GitLab tag is required}"
require_current_tag
: "${DOCKERHUB_TOKEN:?configure a Docker Hub write token in GitLab}"
repo=docker.io/youzifeile/chirp-server
github_owner=YouZiFeiLe
github_repo=Chirp
github_url="https://github.com/${github_owner}/${github_repo}.git"
github_api="https://api.github.com/repos/${github_owner}/${github_repo}"
version=$CI_COMMIT_TAG
# Keep ordinary Git tag names. Encode names reserved here or unsupported by Docker.
case "$version" in
    latest|git-tag-*|[!a-zA-Z0-9_]*|*[!a-zA-Z0-9_.-]*) version='' ;;
esac
if [ -z "$version" ] || [ "${#version}" -gt 128 ]; then
    tag_hash=$(printf '%s' "$CI_COMMIT_TAG" | git hash-object --stdin)
    version="git-tag-$tag_hash"
fi

umask 077
work=$(mktemp -d)
local_image="chirp-release-check:${CI_JOB_ID:?}"
cleanup() {
    docker image rm "$local_image" >/dev/null 2>&1 || :
    rm -rf "$work"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

docker build --pull --platform linux/amd64 --target public --build-arg "CHIRP_VERSION=$CI_COMMIT_TAG" \
    -f deploy/Dockerfile -t "$local_image" .
docker run --rm -i --network none --read-only "$local_image" authorization \
    -key-file /usr/share/chirp/authorization-key.default -verify-trust /dev/stdin \
    < Client/apple/Shared/Resources/AuthorizationTrust.json

sh scripts/test-open-source-compose.sh "$local_image"

require_current_tag
git fetch --quiet --no-tags --depth=20 "$github_url" refs/heads/main
github_tip=$(git rev-parse --verify FETCH_HEAD)
tree=$(git rev-parse --verify "${CI_COMMIT_SHA}^{tree}")
github_tree=$(git rev-parse --verify "${github_tip}^{tree}")
if [ "$tree" != "$github_tree" ]; then
    : "${GITHUB_PUSH_TOKEN:?configure GITHUB_PUSH_TOKEN (with Contents & Pull requests read/write) in GitLab}"
fi

# Limit registry credentials to this job. Keep the runner's existing Docker configuration intact.
mkdir "$work/docker"
printf '%s\n' "$DOCKERHUB_TOKEN" | docker --config "$work/docker" login \
    --username "${DOCKERHUB_USERNAME:-youzifeile}" --password-stdin
docker tag "$local_image" "$repo:$version"
docker --config "$work/docker" push "$repo:$version"

require_current_tag
if [ "$tree" != "$github_tree" ]; then
    fetch_gitlab_history
    base_sha=$(find_sync_base "$github_tip" "$github_tree")
    commits_plain=$(collect_commits "$base_sha" '- %h %s (%cs)')
    commits_md=$(collect_commits "$base_sha" '- `%h` %s (%cs)')
    if [ -z "$commits_plain" ]; then
        commits_plain=$(git log -1 --format='- %h %s (%cs)' "$CI_COMMIT_SHA")
        commits_md=$(git log -1 --format='- `%h` %s (%cs)' "$CI_COMMIT_SHA")
    fi

    publish_time=$(TZ=Asia/Hong_Kong date '+%Y-%m-%d %H:%M:%S %z')
    pr_branch="release/${version}"

    cat > "$work/commit-msg.txt" <<EOF
release: sync ${CI_COMMIT_TAG} from GitLab

Synced from GitLab push-to-github (${publish_time}).

Included GitLab commits:
${commits_plain}

GitLab-Tag: ${CI_COMMIT_TAG}
GitLab-Commit: ${CI_COMMIT_SHA}
EOF

    snapshot=$(git -c user.name='Chirp Release' -c user.email='release@chirp.invalid' \
        commit-tree "$tree" -p "$github_tip" -F "$work/commit-msg.txt")
    github_credential='!credentials() {
        if [ "$1" = get ]; then
            printf "username=x-access-token\npassword=%s\n" "$GITHUB_PUSH_TOKEN"
        fi
    }; credentials'
    git -c credential.helper= -c "credential.helper=$github_credential" \
        push --force --no-follow-tags "$github_url" "$snapshot:refs/heads/$pr_branch"

    escaped_token=$(printf '%s' "$GITHUB_PUSH_TOKEN" | json_escape_string)
    cat > "$work/curl.cfg" <<EOF
header = "Authorization: Bearer ${escaped_token}"
header = "Accept: application/vnd.github+json"
header = "X-GitHub-Api-Version: 2022-11-28"
header = "User-Agent: chirp-release-ci"
EOF

    printf 'chore(release): sync %s from GitLab\n' "$CI_COMMIT_TAG" > "$work/pr-title.txt"
    cat > "$work/pr-body.md" <<EOF
Sync changes from GitLab \`push-to-github\` @ \`${CI_COMMIT_TAG}\` (${publish_time}).

### Included GitLab Commits
${commits_md}

---
- GitLab-Tag: \`${CI_COMMIT_TAG}\`
- GitLab-Commit: \`${CI_COMMIT_SHA}\`
EOF

    build_pr_payload "$work/pr-title.txt" "$pr_branch" "main" "$work/pr-body.md" "$work/pr-payload.json"
    github_api_request GET "${github_api}/pulls?state=open&head=${github_owner}:${pr_branch}&base=main" "" "$work/pulls.json"
    existing_pr=$(parse_open_pr_number < "$work/pulls.json")
    if [ -n "$existing_pr" ]; then
        github_api_request PATCH "${github_api}/pulls/${existing_pr}" "$work/pr-payload.json" "$work/pr-result.json"
        pr_action="Updated pull request #${existing_pr}"
    else
        github_api_request POST "${github_api}/pulls" "$work/pr-payload.json" "$work/pr-result.json"
        pr_action="Created pull request"
    fi
    pr_url=$(parse_pr_url < "$work/pr-result.json")
    printf '%s: %s\n' "$pr_action" "${pr_url:-$pr_branch}"
else
    printf 'GitHub main already matches %s; skipping pull request.\n' "$CI_COMMIT_TAG"
fi

docker tag "$local_image" "$repo:latest"
docker --config "$work/docker" push "$repo:latest"
printf 'Published %s:%s and %s:latest\n' "$repo" "$version" "$repo"
