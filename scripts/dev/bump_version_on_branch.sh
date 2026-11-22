#!/bin/sh
# The version-bump workflow's job (.github/workflows/bump-version.yml, see "Versions" in docs/DEVELOPMENT.md):
# raises the version on $BRANCH with scripts/dev/bump_version.sh and commits it there through GitHub's GraphQL
# API, so GitHub signs the commit. Leaves the version alone when a person set it, or when it already changed
# after this push. Run from the repo root.
#
# Needs: GH_TOKEN (contents: write), GITHUB_REPOSITORY (owner/name), BRANCH, AFTER (the pushed commit) and
# BEFORE (the branch head before the push; may be missing or all zeros).
set -eu

: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${BRANCH:?}" "${AFTER:?}"
BEFORE="${BEFORE:-}"
root=$(pwd)

version_at() { git show "$1:project.godot" | sed -n 's/^config\/version="\(.*\)"$/\1/p'; }

# A PR that raises the version by hand (a minor or major release) keeps its number.
if [ -n "$BEFORE" ] && git cat-file -e "$BEFORE^{commit}" 2>/dev/null \
	&& [ "$(version_at "$BEFORE")" != "$(version_at "$AFTER")" ]; then
	echo "This push set the version itself ($(version_at "$BEFORE") -> $(version_at "$AFTER")); leaving it."
	exit 0
fi
pushed=$(version_at "$AFTER")

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Runs can queue behind each other, and more merges can land while one runs. Bump only while the branch still
# has the version this push had: if it changed since, a bump covering this push already landed, or a later PR
# set the version by hand, and a bump on top of that would turn its 0.3.0 into 0.3.1. The commit names the head
# it builds on, so if another push lands first it's refused and the loop looks again.
attempt=1
while [ "$attempt" -le 3 ]; do
	git fetch -q origin "$BRANCH"
	head=$(git rev-parse FETCH_HEAD)
	current=$(version_at "$head")
	if [ "$current" != "$pushed" ]; then
		echo "The version on $BRANCH changed after this push ($pushed -> $current); leaving it."
		exit 0
	fi

	git show "$head:project.godot" > "$tmp/project.godot"
	git show "$head:export_presets.cfg" > "$tmp/export_presets.cfg"
	(cd "$tmp" && "$root/scripts/dev/bump_version.sh")
	version=$(sed -n 's/^config\/version="\(.*\)"$/\1/p' "$tmp/project.godot")

	jq -n \
		--arg repo "$GITHUB_REPOSITORY" --arg branch "$BRANCH" --arg head "$head" \
		--arg message "Bump version to $version" \
		--arg project "$(base64 < "$tmp/project.godot" | tr -d '\n')" \
		--arg presets "$(base64 < "$tmp/export_presets.cfg" | tr -d '\n')" \
		'{
			query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
			variables: { input: {
				branch: { repositoryNameWithOwner: $repo, branchName: $branch },
				expectedHeadOid: $head,
				message: { headline: $message },
				fileChanges: { additions: [
					{ path: "project.godot", contents: $project },
					{ path: "export_presets.cfg", contents: $presets }
				] }
			} }
		}' > "$tmp/request.json"

	# On a refusal gh still prints the response body to stdout, so look for the new commit's id in it.
	gh api graphql --input "$tmp/request.json" > "$tmp/response" 2>&1 || true
	oid=$(jq -r '.data.createCommitOnBranch.commit.oid // empty' "$tmp/response" 2>/dev/null || true)
	if echo "$oid" | grep -Eq '^[0-9a-f]{40}$'; then
		echo "Committed \"Bump version to $version\" as $oid."
		exit 0
	fi
	echo "The commit was refused: $(cat "$tmp/response")"
	echo "Looking again ($attempt/3)."
	attempt=$((attempt + 1))
done
echo "The commit kept being refused; giving up."
exit 1
