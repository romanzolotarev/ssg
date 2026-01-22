#!/bin/sh -eu
fail() { echo "$@" >&2 && exit 1; }
check_args() {
	if test "$#" -ne 2; then fail "usage: ${0##*/} <site> <server>"; fi
	if ! test -d "$1"; then fail "fail: $1 not a directory"; fi
}

copy_files() { rsync -licr --delete --delete-excluded "$1/" "$2/"; }
pretty() { grep -Ev '^$|/$' >&2 || :; }

chown_dir() { echo 'chown -R www:staff "'"$1"'"'; }
hash_dir() {
	echo 'find "'"$1"'" -type f ! -name ".ssg.src" ! -name ".ssg.dst" -print0 |
	xargs -0 -n256 sha256 -r | sed "s, '"$1"'/, ," | sort | sha256'
}
remote_hash_dir() { (chown_dir "$1" && hash_dir "$1") | ssh -T "$2"; }
remote_size_dir() { echo 'du -hd0 "'"$1"'" | cut -f1' | ssh -T "$2"; }

main() {
	check_args "$@"
	site=$(basename "$1")
	remote_dir="/var/www/htdocs/${site:?}"
	copy_files "$1" "$2:$remote_dir" | pretty
	hash=$(remote_hash_dir "$remote_dir" "$2")
	size=$(remote_size_dir "$remote_dir" "$2")
	echo "$hash" "$site" "$2" "$size"
}

main "$@"
