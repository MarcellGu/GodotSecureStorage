#!/bin/sh
set -eu

if [ "${GITHUB_ACTIONS:-}" != true ]; then
	exit 0
fi

cache_key=${1:-}
cache_scope=${2:-current-and-default}
test -n "$cache_key"
case "$cache_scope" in
	current-ref|current-and-default) ;;
	*) exit 1 ;;
esac
test -n "${GH_TOKEN:-}"
test -n "${GITHUB_REPOSITORY:-}"
test -n "${GITHUB_REF:-}"
test -n "${REPOSITORY_DEFAULT_BRANCH:-}"

find_cache_ids() {
	cache_ref=$1
	tab=$(printf '\t')
	cache_rows=$(gh api --method GET "repos/$GITHUB_REPOSITORY/actions/caches" \
		-f key="$cache_key" \
		-f ref="$cache_ref" \
		-f per_page=100 \
		--jq '.actions_caches[] | [.id, .key, .ref] | @tsv')
	printf '%s\n' "$cache_rows" |
		while IFS="$tab" read -r cache_id result_key result_ref; do
			if [ "$result_key" = "$cache_key" ] &&
				[ "$result_ref" = "$cache_ref" ]; then
				printf '%s\n' "$cache_id"
			fi
	done
}

default_ref="refs/heads/$REPOSITORY_DEFAULT_BRANCH"
collect_cache_ids() {
	find_cache_ids "$GITHUB_REF"
	if [ "$cache_scope" = current-and-default ] &&
		[ "$GITHUB_REF" != "$default_ref" ]; then
		find_cache_ids "$default_ref"
	fi
}

cache_ids=$(collect_cache_ids)

report_invalidation() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf 'cache_invalidated=true\n' >>"$GITHUB_OUTPUT"
	fi
}

if [ -z "$cache_ids" ]; then
	echo "缓存已失效：key=$cache_key"
	report_invalidation
	exit 0
fi

for cache_id in $(printf '%s\n' "$cache_ids" | sort -u); do
	case "$cache_id" in
		*[!0-9]*|'') exit 1 ;;
	esac
	if ! gh api --method DELETE \
		"repos/$GITHUB_REPOSITORY/actions/caches/$cache_id"; then
		remaining_ids=$(collect_cache_ids)
		for remaining_id in $remaining_ids; do
			if [ "$remaining_id" = "$cache_id" ]; then
				exit 1
			fi
		done
	fi
done

echo "已使缓存失效：key=$cache_key"
report_invalidation
