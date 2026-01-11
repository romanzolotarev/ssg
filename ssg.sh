#!/bin/ksh -eu

# https://romanzolotarev.com/ssg/
# copyright 2018-2026 romanzolotarev.com
#
# permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# the software is provided "as is" and the author disclaims all warranties with
# regard to this software including all implied warranties of merchantability
# and fitness. in no event shall the author be liable for any special, direct,
# indirect, or consequential damages or any damages whatsoever resulting from
# loss of use, data or profits, whether in an action of contract, negligence or
# other tortious action, arising out of or in connection with the use or
# performance of this software.

info() { echo "$@" >&2; }
fail() { echo "$@" >&2 && exit 1; }
usage() { fail 'usage: '"${0##*/}"' <src> <dst>'; }

# exit if less than two arguments
fail_no_args() { if test $# -ne 2; then usage; fi; }

# exit if src directory not found
fail_no_src() { if ! test -d "$1"; then fail "fail: $1 not found"; fi; }

# return relative paths sorted
sort_relative() { sed "s,$1/,," | sort; }

# return sorted file hashes for directory
hash_dir() {
	dir="$1"
	if ! test -d "$dir"; then return; fi
	set -- find "$dir" -type f
	while read -r line; do
		if test -z "$line"; then continue; fi
		set -f && for word in $line; do
			if test -z "$word"; then continue; fi && set -- "$@" "$word"
		done && set +f
	done
	"$@" -print0 | xargs -r -0 -n256 -P "$NCPU" sha256 -r | sort_relative "$dir"
}

# return find expression to exclude paths
not_path() {
	while read -r x; do
		case "$x" in
		*/) echo "! -path $x*" ;;
		*) echo "! -path $x" ;;
		esac
	done
}

# return all .ssg.ignore files
find_ignore_files() { find "$SRC" -type f -name "$SSG_IGNORE"; }

# return ignored paths from all .ssg.ignore files
ignored_paths() {
	while read -r f; do d="$(dirname "$f")" && sed "s,^,${d}/," "$f"; done
}

# return src directory hash, excluding paths from .ssg.ignore
hash_src() { find_ignore_files | ignored_paths | not_path | hash_dir "$SRC"; }

# return find expression to exclude src and dst hash files
exclude_hash_files() { echo "! -name $SSG_DST ! -name $SSG_SRC"; }

# return dst directory hash, excluding hash files
hash_dst() { exclude_hash_files | hash_dir "$DST"; }

mustache() {
	d=0
	s=-1
	while read -r line; do
		o=""
		rest="$line"
		while :; do
			case "$rest" in
			*'{{'*)
				before="${rest%%\{\{*}"
				rest="${rest#*\{\{}"
				tag="${rest%%\}\}*}"
				rest="${rest#*\}\}}"
				if test $s -lt 0; then o="${o}${before}"; fi
				case "$tag" in
				'#'*)
					d=$((d + 1))
					if test $s -lt 0 -a -z "$(printenv "${tag#\#}")"; then s=$d; fi
					;;
				'/'*) if test $s -eq $d; then s=-1; fi && d=$((d - 1)) ;;
				'^'*)
					d=$((d + 1))
					if test $s -lt 0 -a -n "$(printenv "${tag#^}")"; then s=$d; fi
					;;
				*) if test $s -lt 0; then o="${o}$(printenv "$tag")"; fi ;;
				esac
				;;
			*) if test $s -lt 0; then o="${o}${rest}"; fi && break ;;
			esac
		done
		if test $s -lt 0 -o -n "$o"; then printf '%s\n' "$o"; fi
	done
}

# returns page rendered with its template
render_page() {
	# strip newlines and escape ampersands and slashes
	esc() { tr -d '\n' | sed 's/[&/]/\\&/g'; }
	# replace newlines with spaces and extract title from the first <h1> tag
	get_title() { tr '\n' ' ' |
		sed -n 's/^[^<]*<[Hh]1[^>]*>\([^<]*\)<\/[Hh]1[^>]*>.*/\1/p'; }
	content="$(cat)"
	# use src dir name as site name
	site="$(basename "$SRC" | esc)"
	title="$(printf '%s' "$content" | get_title | esc)"
	# replace {{title}} and {{site}} tags with values from variables,
	# replace {{content}} tag with page content.
	# use truthy tag to show title only when it's found in content, for example:
	# {{#title}}{{title}: {{/title}}
	export content site title && mustache <"$1"
}

# return html converted from markdown
md_to_html() {
	lowdown \
		--out-no-smarty \
		--html-no-escapehtml \
		--html-no-skiphtml \
		--parse-no-autolink \
		--parse-no-metadata
}

# write zip unless its gz variant found in src
gz() {
	if test -f "$SRC/$1.gz"; then return; fi
	gzip -n -9 <"$DST/$1" >"$DST/$1.gz"
}

# return nearest template for page
find_template() {
	dir=$(cd "$(dirname "$SRC/$1")" && pwd)
	root=$(dirname "$(cd "$SRC" && pwd)")
	while test "$dir" != "$root"; do
		t="$dir/$SSG_TEMPLATE"
		if test -f "$t"; then echo "${t#"$SRC/"}" && return; fi
		dir=$(dirname "$dir")
	done
}

# return relative paths to files if they found in directory
files_in() {
	while read -r f; do if test -f "$1/$f"; then echo "$f"; fi; done
}

# write and zip file to dst
generate_file() {
	mkdir -p "$(dirname "$DST/$1")"
	cp "$SRC/$1" "$DST/$1"
	info "file      $1"
	gz "$1"
	info "file      $1 > $1.gz"
}

# write file to dst
generate_copy() {
	mkdir -p "$(dirname "$DST/$1")"
	cp "$SRC/$1" "$DST/$1"
	info "copy      $1"
}

# execute script and write zips for output files to dst
generate_sh() {
	command ksh -- "$SRC/$1" "$SRC" "$DST" |
		while read -r f; do
			if test -z "$f"; then continue; fi
			if test -f "$SRC/$f"; then fail "fail: $1 collides with $f"; fi
			info "sh        $1 > $f"
			gz "$f"
			info "sh        $1 > $f.gz"
		done
}

# return true page has <html> tag
has_html_tag() { grep -qi '<html[^>]*>' "$SRC/$1"; }

# write html page and zip to dst
generate_html() {
	mkdir -p "$(dirname "$DST/$1")"

	# return content as is for pages with <html> tag
	if has_html_tag "$1"; then
		cp "$SRC/$1" "$DST/$1"
		info "html      $1"
		gz "$1"
		info "html      $1 > $1.gz"
		return
	fi

	# find template
	t=$(find_template "$1")

	if test -f "$SRC/$t"; then
		# return page rendered with template
		render_page "$SRC/$t" <"$SRC/$1" >"$DST/$1"
		info "html      $1, $t > $1"
		gz "$1"
		info "html      $1, $t > $1.gz"
	else
		# ...or return content as is if template not found
		cp "$SRC/$1" "$DST/$1"
		info "html      $1"
		gz "$1"
		info "html      $1 > $1.gz"
	fi
}

# write markdown page and zip to dst
generate_md() {
	mkdir -p "$(dirname "$DST/$1")"
	t=$(find_template "$1")
	h="${1%.md}.html"
	if test -f "$SRC/$h"; then fail "fail: $1 collides with $h"; fi
	if test -f "$SRC/$t"; then
		md_to_html <"$SRC/$1" | render_page "$SRC/$t" >"$DST/$h"
		info "md        $1, $t > $h"
		gz "$h"
		info "md        $1, $t > $h.gz"
	else
		md_to_html <"$SRC/$1" >"$DST/$h"
		info "md        $1 > $h"
		gz "$h"
		info "md        $1 > $h.gz"
	fi
}

# return diff of two values
diff_lines() {
	fifo=$(mktemp -u) || fail 'fail: diff lines: can not mktemp'
	mkfifo "$fifo" || fail 'fail: diff lines: can not mkfifo'
	(printf '%s\n' "$2" >"$fifo") &
	printf '%s\n' "$1" | diff - "$fifo" || :
	rm -f "$fifo"
}

# return second column and sort
cut_sort() { cut -d' ' -f2 | sort; }

# return pages with their templates, excluding pages with <html> tag
pages_with_templates() {
	while read -r p; do
		if has_html_tag "$p"; then continue; fi &&
			printf '%s\t%s\n' "$(find_template "$p")" "$p"
	done
}

# return pages related to template
pages_by_templates() {
	grep "$SSG_TEMPLATE" | cut_sort |
		while read -r t; do echo "$1" | grep "$t" | cut -f2; done
}

# return file expected in dst directory
plan() {
	while read -r k f; do
		case "$k" in
		copy) echo "$f" ;;
		file) echo "$f" && echo "$f.gz" ;;
		html) echo "$f" && echo "$f.gz" ;;
		md) echo "${f%.md}.html" && echo "${f%.md}.html.gz" ;;
		sh) command ksh -- "$SRC/$f" |
			while read -r f; do
				if test -z "$f"; then continue; fi && echo "$f" && echo "$f.gz"
			done ;;
		*) continue ;;
		esac
	done
}

# make dst directory and return src hash as is
mkdir_select_all() { mkdir -p "$DST" && echo "$1" | cut_sort; }

# remove dst directory and return src hash as is
rmdir_select_all() { rm -rf "$DST" && echo "$1" | cut_sort; }

# remove files in dst
rm_files() { while read -r f; do rm "$DST/$f" && info "rm        $f"; done; }

# remove empty directories in dst
rm_empty_dirs() {
	find "$DST" -type d -mindepth 1 | while read -r d; do
		if test -z "$(find "$d" -mindepth 1 -type f)"; then echo "$d"; fi
	done | sort -r | while read -r e; do
		rmdir "$e" && info "rmdir     ${e#"$DST"/}/"
	done
}

# return files with their kind prepended
prepend_kind() {
	while read -r f; do
		if test -z "$f"; then continue; fi
		case "$f" in
		*.html) k='html' ;;
		*.md) k='md' ;;
		*.ssg.ignore) k='ignore' ;;
		*.ssg.*.sh | *.ssg.sh) k='sh' ;;
		*.ssg.template) k='template' ;;
		*.png | *.jpg | *.gif | *.mp4 | *.zip | *.gz) k='copy' ;;
		*) k='file' ;;
		esac
		echo "$k $f"
	done
}

# return right side of diff
select_right() { sed -n 's/^> \([^\	]*\).*/\1/p'; }

# remove files and directories not present in plan from dst
clean_up_dst() {
	dst_plan=$(echo "$1" | cut_sort | prepend_kind | plan | sort)
	dst_files=$(echo "$2" | sort_relative "$DST" | cut_sort)
	diff_lines "$dst_plan" "$dst_files" | select_right | files_in "$DST" |
		rm_files
	rm_empty_dirs
}

# return sorted list of unique updated files and pages for updated template
select_updated() {
	src_updated=$(echo "$2" | select_right | cut_sort)
	pages=$(echo "$1" | grep -E '.html|.md' | cut_sort | pages_with_templates)
	{
		echo "$src_updated"
		echo "$src_updated" | pages_by_templates "$pages"
	} | sort -u
}

is_empty() { test -z "$1"; }
is_dir() { test -d "$1"; }
is_ssg_dst() { test -f "$DST/$SSG_DST"; }
is_ssg_src() { test -f "$DST/$SSG_SRC"; }
is_matching_ssg_dst() {
	test "$(sha256 <"$DST/$SSG_DST")" = "$(echo "$1" | sha256)"
}
diff_src() { diff_lines "$(cat "$DST/$SSG_SRC")" "$1"; }

# return files to be updated
select_src_files() {
	if is_empty "$1"; then return; fi
	if ! is_dir "$DST"; then mkdir_select_all "$1" && return; fi
	if ! is_ssg_src || ! is_ssg_dst; then rmdir_select_all "$1" && return; fi
	dst_hash=$(hash_dst)
	if ! is_matching_ssg_dst "$dst_hash"; then rmdir_select_all "$1" && return; fi
	src_hash_diff=$(diff_src "$1")
	if is_empty "$src_hash_diff"; then return; fi
	clean_up_dst "$src_hash" "$dst_hash"
	select_updated "$src_hash" "$src_hash_diff"
}

# write files in dst directory
generate() {
	while read -r k f; do
		case "$k" in
		copy) generate_copy "$f" ;;
		file) generate_file "$f" ;;
		html) generate_html "$f" ;;
		md) generate_md "$f" ;;
		sh) generate_sh "$f" ;;
		template) info "template  $f" ;;
		ignore) info "ignore    $f" ;;
		*) info "unknown   $f" ;;
		esac
	done
}

# write src and dst hash files to dst directory
write_hashes() {
	if ! test -d "$DST"; then return; fi
	echo "$1" >"$DST/$SSG_SRC"
	echo "$2" | tee "$DST/$SSG_DST" | sha256 >&2
}

main() {
	fail_no_args "${@}"
	fail_no_src "${@}"

	SRC=$(cd "$1" && pwd)
	DST="$2"
	SSG_IGNORE='.ssg.ignore'
	SSG_TEMPLATE='.ssg.template'
	SSG_SRC='.ssg.src'
	SSG_DST='.ssg.dst'
	NCPU=$(sysctl -n hw.ncpu 2>/dev/null || getconf NPROCESSORS_ONLN)

	src_hash=$(hash_src)
	select_src_files "$src_hash" | prepend_kind | generate
	write_hashes "$src_hash" "$(hash_dst)"
}

main "${@}"
