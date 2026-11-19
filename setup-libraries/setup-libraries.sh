#!/usr/bin/env bash
#
# Clones the packages a plugin installs from Composer path repositories, so
# `composer install` finds them where it would on the machine that wrote the
# lock.
#
# With a composer.lock: every path package whose name matches PACKAGES, at the
# commit the lock recorded (dist.reference -- Composer stores the path's git
# HEAD there), into the folder the lock recorded (dist.url).
#
# Without one: every matching package composer.json requires, and what those
# require in turn, at the tip of each repository's default branch, into the
# folder the matching path repository points at.
#
# Settings come from the environment: WORKING_DIRECTORY, PACKAGES, TOKEN,
# SERVER, PARALLEL.

set -euo pipefail

working_directory="${WORKING_DIRECTORY:-.}"
packages="${PACKAGES:-^(sugarcommerce/.+|arraypress/edd-registrars)$}"
token="${TOKEN:-}"
server="${SERVER:-https://github.com}"
parallel="${PARALLEL:-8}"

cd "$working_directory"

if [ ! -f composer.json ]; then
	echo "::error::No composer.json in $(pwd)"
	exit 1
fi

auth=()
if [ -n "$token" ]; then
	auth=(-c "http.${server}/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')")
fi

# One package, one shallow fetch. $ref is a commit, or empty for the default
# branch. $branch is the name the checkout gets, so Composer reads the same
# version off it (dev-main) that it recorded.
clone() {
	local name="$1" ref="$2" dest="$3" branch="$4"
	local url="${server}/${name}.git"

	if [ -n "$ref" ] && [ -d "$dest/.git" ] && [ "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" = "$ref" ]; then
		echo "$name: already at ${ref:0:12} in $dest"
		return 0
	fi

	rm -rf "$dest"
	mkdir -p "$dest"
	git -C "$dest" init -q
	git -C "$dest" remote add origin "$url"

	# A stalled connection gives up after 30 seconds under 1 KB/s instead of
	# hanging the job, and gets two more tries.
	local try=1
	until git ${auth[@]+"${auth[@]}"} -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
		-C "$dest" fetch -q --depth 1 --no-tags origin "${ref:-HEAD}"; do
		if [ "$try" -ge 3 ]; then
			break
		fi
		try=$((try + 1))
		echo "$name: fetch failed, trying again ($try of 3)"
		sleep $((try * 2))
	done

	if [ "$(git -C "$dest" rev-parse -q --verify FETCH_HEAD 2>/dev/null)" = "" ]; then
		if [ -n "$ref" ]; then
			echo "::error::$name: could not fetch commit $ref from $url. Is it pushed?"
		else
			echo "::error::$name: could not fetch $url"
		fi
		return 1
	fi

	if [ -n "$branch" ]; then
		git -C "$dest" checkout -q -B "$branch" FETCH_HEAD
	else
		git -C "$dest" checkout -q --detach FETCH_HEAD
	fi

	echo "$name: $(git -C "$dest" rev-parse --short=12 HEAD) in $dest"
}

# Runs clone() over a tab-separated list (name, ref, dest, branch; "-" for
# none, since read folds empty tab fields away), a few at a time. Fails if any
# of them did.
clone_all() {
	local list="$1" failed=0 running=0
	local pids=()

	while IFS=$'\t' read -r name ref dest branch; do
		[ -n "$name" ] || continue
		[ "$ref" != "-" ] || ref=""
		[ "$branch" != "-" ] || branch=""
		clone "$name" "$ref" "$dest" "$branch" &
		pids+=("$!")
		running=$((running + 1))

		if [ "$running" -ge "$parallel" ]; then
			wait "${pids[0]}" || failed=1
			pids=("${pids[@]:1}")
			running=$((running - 1))
		fi
	done <"$list"

	for pid in "${pids[@]+"${pids[@]}"}"; do
		wait "$pid" || failed=1
	done

	return "$failed"
}

list="$(mktemp)"
trap 'rm -f "$list"' EXIT

if [ -f composer.lock ]; then
	echo "Reading composer.lock in $(pwd)"

	jq -r --arg re "$packages" '
		(.packages + (."packages-dev" // []))[]
		| select(.dist.type == "path" and (.name | test($re)))
		| [ .name, (.dist.reference // "-"), .dist.url, (.version | if startswith("dev-") then .[4:] else "-" end) ]
		| @tsv
	' composer.lock | while IFS=$'\t' read -r name ref path branch; do
		if [ "$ref" = "-" ]; then
			echo "::warning::$name: the lock records no commit, so this is the tip of its default branch" >&2
		fi
		printf '%s\t%s\t%s\t%s\n' "$name" "$ref" "$path" "$branch"
	done >"$list"

	jq -r --arg re "$packages" '
		(.packages + (."packages-dev" // []))[]
		| select(.dist.type == "path" and (.name | test($re) | not))
		| .name
	' composer.lock | while read -r name; do
		echo "::warning::$name installs from a path repository but does not match '$packages', so it was not cloned"
	done

	if [ ! -s "$list" ]; then
		echo "Nothing to clone: no path packages matching '$packages' in composer.lock"
		exit 0
	fi

	clone_all "$list"
	exit $?
fi

echo "::notice::No composer.lock in $(pwd): cloning the tip of each package's default branch, not a recorded commit"

# The path repositories, as urls.
urls=()
while IFS= read -r url; do
	urls+=("$url")
done < <(jq -r '
	(.repositories // []) | (if type == "object" then [ .[] ] else . end)[]
	| select(type == "object" and .type == "path") | .url
' composer.json)

# The folder a package lives in: a path repository named for it, else the
# first wildcard one ("../libraries/sugarcommerce/*").
path_for() {
	local name="$1" base="${1#*/}" url

	for url in "${urls[@]+"${urls[@]}"}"; do
		if [ "${url##*/}" = "$base" ]; then
			echo "$url"
			return
		fi
	done

	for url in "${urls[@]+"${urls[@]}"}"; do
		if [ "${url##*/}" = "*" ]; then
			echo "${url%/*}/$base"
			return
		fi
	done
}

# The matching packages a composer.json requires, with the branch its
# constraint names (dev-main -> main).
requires() {
	jq -r --arg re "$packages" --arg dev "$2" '
		(.require // {}) + (if $dev == "1" then (."require-dev" // {}) else {} end)
		| to_entries[]
		| select(.key | test($re))
		| [ .key, (.value | if startswith("dev-") then .[4:] else "-" end) ]
		| @tsv
	' "$1"
}

seen=" "
queue="$(requires composer.json 1)"

while [ -n "$queue" ]; do
	: >"$list"
	added=()

	while IFS=$'\t' read -r name branch; do
		[ -n "$name" ] || continue
		case "$seen" in *" $name "*) continue ;; esac
		seen="$seen$name "

		path="$(path_for "$name")"
		if [ -z "$path" ]; then
			echo "::error::$name: no path repository in composer.json to put it in"
			exit 1
		fi

		printf '%s\t-\t%s\t%s\n' "$name" "$path" "$branch" >>"$list"
		added+=("$path")
	done <<<"$queue"

	[ -s "$list" ] || break
	clone_all "$list"

	queue=""
	for dest in ${added[@]+"${added[@]}"}; do
		if [ -f "$dest/composer.json" ]; then
			queue="$queue$(requires "$dest/composer.json" 0)"$'\n'
		fi
	done
done
