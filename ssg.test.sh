#!/bin/ksh -e

ok_count=0
ok_expected=28

plan() {
	echo "$ok_expected..$ok_count"
	test "$ok_expected" -eq "$ok_count" || { echo 'failed' && exit 1; }
	echo 'passed' && exit 0
}

bench() {
	i="$1" && shift
	exec 3>&1
	{
		time (
			n=1 && printf . >&3
			while [ "$n" -le "$i" ]; do
				"$@" >/dev/null 2>&1 && n=$((n + 1))
				printf . >&3
			done
			printf '\n' >&3
		)
	} 2>&1 | grep 'real' | cut -f2 | cut -d' ' -f5
	exec 3>&-
}

ok() { echo "ok: $*" && ok_count=$((ok_count + 1)); }
not_ok() { echo "not ok: $*" && plan; }

not_ok_diff_n() {
	fifo=$(mktemp -u) || exit 1
	mkfifo "$fifo" || exit 1
	(printf "%s" "$2" >"$fifo") &
	printf "\n%s\n" "$(cat)" | diff - "$fifo" || not_ok "$1"
	rm -f "$fifo"
}

not_ok_diff() {
	fifo=$(mktemp -u) || exit 1
	mkfifo "$fifo" || exit 1
	(echo "$2" >"$fifo") &
	diff - "$fifo" || not_ok "$1"
	rm -f "$fifo"
}

not_ok_find() {
	find "$1" -type f | sort | sed "s,$1/,," | not_ok_diff_n "$2" "$3"
}

base=$(dirname "$0")
cmd="$base/ssg.sh"
test -x "$cmd" || { echo "$cmd not found" >&2 && exit 1; }

basic_case() {
	dir=$(mktemp -d)
	src="$dir/src" && dst="$dir/dst"
	mkdir "$src" "$src/.git"
	echo '# h1' >"$src/markdown.md"
	echo '<h1>h1</h1>' >"$src/html1.html"
	echo '<html>' >"$src/html2.html"
	echo '<title>{{title}}:{{site}}</title>{{content}}' >"$src/.ssg.template"
	echo '.git/' >"$src/.ssg.ignore"
	echo >"$src/.git/index"
	echo >"$src/main.css"
	echo >"$src/logo.png"
	# shellcheck disable=2016
	echo '
if test -z "$1"; then echo "x.txt" && exit; fi
echo . >"$2/x.txt" && echo "x.txt"
' >"$src/.ssg.sh"
	"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "basic_case" '
ignore    .ssg.ignore
sh        .ssg.sh > x.txt
sh        .ssg.sh > x.txt.gz
template  .ssg.template
html      html1.html, .ssg.template > html1.html
html      html1.html, .ssg.template > html1.html.gz
html      html2.html
html      html2.html > html2.html.gz
copy      logo.png
file      main.css
file      main.css > main.css.gz
md        markdown.md, .ssg.template > markdown.html
md        markdown.md, .ssg.template > markdown.html.gz
sitemap   sitemap.xml
sitemap   robots.txt
de31b4842cafa9761c3bb57c9d60b7651e93f9606dbb5a40f760caefda2f34ea
'
	rm -rf "$dir"
}

t() {
	dir=$(mktemp -d) && src="$dir/src" && dst="$dir/dst"
	case "$1" in

	fail_no_args)
		if "$cmd" "$src" 2>/dev/null; then
			exit_code="$?" && test "$exit_code" -eq 1 ||
				not_ok "$1: expected: exit code 1, actual: exit code $exit_code"
		fi
		test -d "$dst" && not_ok "$1"
		;;

	fail_no_src)
		if "$cmd" "$src" "$dst" 2>/dev/null; then
			exit_code="$?" && test "$exit_code" -eq 1 ||
				not_ok "$1: expected: exit code 1, actual: exit code $exit_code"
		fi
		test -d "$dst" && not_ok "$1"
		;;

	select_src_files_empty_src)
		mkdir "$src" "$dst" && "$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1" '
01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b
'
		not_ok_find "$dst" "$1: dst not empty" '
.ssg.dst
.ssg.src
'
		;;

	select_src_files_ssg_ignore)
		mkdir "$src" "$src/a" "$src/a/b" "$src/a/c"
		echo '1.txt' >"$src/.ssg.ignore"
		echo '2.txt
c/' >"$src/a/.ssg.ignore"
		echo '3.txt' >"$src/a/b/.ssg.ignore"
		echo >"$src/1.txt"
		echo >"$src/a/2.txt"
		echo >"$src/a/b/3.txt"
		echo >"$src/a/c/4.txt"
		echo >"$src/a/c/5.txt"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1" '
ignore    .ssg.ignore
ignore    a/.ssg.ignore
ignore    a/b/.ssg.ignore
01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
'
		;;

	select_src_files_trailing_slash)
		mkdir "$src" && echo >"$src/t.png"
		"$cmd" "$src"/ "$dst"/ 2>&1 | not_ok_diff_n "$1" '
copy      t.png
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		not_ok_find "$dst" "$1: dst has t.png" '
.ssg.dst
.ssg.src
t.png
'
 cat "$dst/.ssg.dst" | not_ok_diff_n "$1: .ssg.dst" '
01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b t.png
'
		;;

	select_src_files_no_dst)
		mkdir "$src" && echo >"$src/t.png"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1" '
copy      t.png
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		not_ok_find "$dst" "$1: dst has t.png" '
.ssg.dst
.ssg.src
t.png
'
		;;

	select_src_files_no_ssg_dst_ssg_src)
		mkdir "$src" "$dst" && echo >"$src/t.png"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
copy      t.png
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		rm "$dst/.ssg.src"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
copy      t.png
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		rm "$dst/.ssg.dst"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: third run" '
copy      t.png
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		;;

	select_src_files_no_dst_ssg_dst_match)
		mkdir "$src" "$dst" && echo >"$src/t.png"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
copy      t.png
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		echo x >>"$dst/.ssg.dst"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
copy      t.png
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		;;

	select_src_files_no_src_diff)
		mkdir "$src" "$dst" && echo >"$src/t.png"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
copy      t.png
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		;;

	select_src_files_clean_dst)
		mkdir "$src" && echo >"$src/t.png"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
copy      t.png
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		echo >"$dst/trash_file"
		mkdir "$dst/trash_dir"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
copy      t.png
9db7b136bc6fdd9c51009ce2f88c69ff64060c3f3ff540a9199f37d2aa404eaa
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
t.png
'
		;;

	select_src_files_clean_dst_dir)
		mkdir "$src" "$src/dir"
		echo >"$src/a.png"
		echo >"$src/dir/b.png"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
copy      a.png
copy      dir/b.png
6e0b941542f81e1b299a21444d0efe2fa224a4220e67df9c37cc34a2c6f01b13
'
		rm "$src/dir/b.png"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
rm        dir/b.png
rmdir     dir/
e86615a87eeeae97fb6302dd5013109f0ccfb7336f164a39457e684c30bae90e
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
a.png
'
		;;

	select_updated)
		mkdir "$src" "$dst"
		echo '<title></title>' >"$src/.ssg.template"
		echo '<h1>h1</h1>' >"$src/html1.html"
		echo '<html>' >"$src/html2.html"
		echo '# h1' >"$src/markdown.md"
		echo >"$src/t.png"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
template  .ssg.template
html      html1.html, .ssg.template > html1.html
html      html1.html, .ssg.template > html1.html.gz
html      html2.html
html      html2.html > html2.html.gz
md        markdown.md, .ssg.template > markdown.html
md        markdown.md, .ssg.template > markdown.html.gz
copy      t.png
sitemap   sitemap.xml
sitemap   robots.txt
e58355d68978971708283c3099a1f15c2f4514964e1456af3a2c554db93af090
'

		expected_dst='
.ssg.dst
.ssg.src
html1.html
html1.html.gz
html2.html
html2.html.gz
markdown.html
markdown.html.gz
robots.txt
sitemap.xml
t.png
'
		not_ok_find "$dst" "$1" "$expected_dst"

		echo 'x' >"$src/.ssg.template"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
template  .ssg.template
html      html1.html, .ssg.template > html1.html
html      html1.html, .ssg.template > html1.html.gz
md        markdown.md, .ssg.template > markdown.html
md        markdown.md, .ssg.template > markdown.html.gz
cc2f8fab08e743666d490c9379e8580981115d95c3b6492893a46b5cd30f5f3a
'
		not_ok_find "$dst" "$1" "$expected_dst"
		;;

	generate_copy)
		mkdir "$src" "$dst" && echo 'png' >"$src/t.png"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
copy      t.png
5265fde36fa46d08d2bc48d0f413d41c166ee966a4f94b5fd7ad0c23e1bb92d4
'
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
5265fde36fa46d08d2bc48d0f413d41c166ee966a4f94b5fd7ad0c23e1bb92d4
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
t.png
'
		cat "$dst/t.png" | not_ok_diff "$1" 'png'
		;;

	generate_file)
		mkdir "$src" "$dst" && echo 'txt' >"$src/t.txt"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
file      t.txt
file      t.txt > t.txt.gz
482d02d3fdd5ca854ffc9370f9cf3d4efa5bb640713c90dcf5c9800d5acf6812
'
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
482d02d3fdd5ca854ffc9370f9cf3d4efa5bb640713c90dcf5c9800d5acf6812
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
t.txt
t.txt.gz
'
		cat "$dst/t.txt" | not_ok_diff "$1" 'txt'
		hexdump -C "$dst/t.txt.gz" | not_ok_diff_n "$1" '
00000000  1f 8b 08 00 00 00 00 00  02 03 2b a9 28 e1 02 00  |..........+.(...|
00000010  d3 84 7d 34 04 00 00 00                           |..}4....|
00000018
'
		;;

	generate_html)
		mkdir "$src" "$dst" && echo '<html>' >"$src/h.html"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
html      h.html
html      h.html > h.html.gz
sitemap   sitemap.xml
sitemap   robots.txt
c31554e49bd5671f634ec9392a21ded395383d00bf224088767fd2fc64a42486
'
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
c31554e49bd5671f634ec9392a21ded395383d00bf224088767fd2fc64a42486
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
h.html
h.html.gz
robots.txt
sitemap.xml
'
		cat "$dst/h.html" | not_ok_diff "$1" '<html>'
		hexdump -C "$dst/h.html.gz" | not_ok_diff_n "$1" '
00000000  1f 8b 08 00 00 00 00 00  02 03 b3 c9 28 c9 cd b1  |............(...|
00000010  e3 02 00 99 34 cb 33 07  00 00 00                 |....4.3....|
0000001b
'
		;;

	generate_sitemap)
		mkdir "$src" "$dst" && echo '<html>' >"$src/h.html"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
html      h.html
html      h.html > h.html.gz
sitemap   sitemap.xml
sitemap   robots.txt
c31554e49bd5671f634ec9392a21ded395383d00bf224088767fd2fc64a42486
'
		cat "$dst/sitemap.xml" | not_ok_diff_n "$1" '
<?xml version="1.0" encoding="UTF-8"?>
<urlset
	xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
	xsi:schemaLocation="http://www.sitemaps.org/schemas/sitemap/0.9
	http://www.sitemaps.org/schemas/sitemap/0.9/sitemap.xsd"
	xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
	<url><loc>https://src/h.html</loc></url>
</urlset>
'
		rm "$src/h.html"

		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
rm        h.html
rm        h.html.gz
rm        robots.txt
rm        sitemap.xml
01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b
'

		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
'
		;;

	generate_sitemap_xml_found_in_src)
		mkdir "$src" "$dst"
		echo '<html>' >"$src/h.html"
		echo >"$src/sitemap.xml"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
html      h.html
html      h.html > h.html.gz
file      sitemap.xml
file      sitemap.xml > sitemap.xml.gz
8ff598b31385c53268c54ff343e33ff60bbf0605d5efcd4f7c5f84a395eaaaa4
'
		cat "$dst/sitemap.xml" | not_ok_diff "$1" ''
		;;

	generate_sitemap_robots_txt_found_in_src)
		mkdir "$src" "$dst"
		echo '<html>' >"$src/h.html"
		echo >"$src/robots.txt"
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
html      h.html
html      h.html > h.html.gz
file      robots.txt
file      robots.txt > robots.txt.gz
sitemap   sitemap.xml
380bbf740dad47d4036e88e89a07b7a1d1f94657ca5bcf9e5f10f1feddd8c799
'
		cat "$dst/robots.txt" | not_ok_diff "$1" ''
		;;

	generate_html_with_template_title)
		mkdir "$src" "$dst"
		echo '<h>b<h1 id="h1" >'\''&rarr;<a href=""></a>
nl</h1>a
<p>a</p></h>' >"$src/h.html"
		echo '<title>{{title}}</title>' >"$src/.ssg.template"

		"$cmd" "$src" "$dst" 2>/dev/null
		cat "$dst/h.html" | not_ok_diff "$1: h.html" "<title>'&rarr; nl</title>"
		;;

	generate_html_with_template)
		mkdir "$src" "$dst"
		echo '<h1>x</h1>' >"$src/h.html"
		echo '<title>{{title}}~{{site}}</title>{{content}}' >"$src/.ssg.template"

		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
template  .ssg.template
html      h.html, .ssg.template > h.html
html      h.html, .ssg.template > h.html.gz
sitemap   sitemap.xml
sitemap   robots.txt
5843646b566cdf923e8cb8745d6e516dc1d764e4af5894a823d6aef45b61f70e
'
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
5843646b566cdf923e8cb8745d6e516dc1d764e4af5894a823d6aef45b61f70e
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
h.html
h.html.gz
robots.txt
sitemap.xml
'

		cat "$dst/h.html" | not_ok_diff "$1" '<title>x~src</title><h1>x</h1>'
		hexdump -C "$dst/h.html.gz" | not_ok_diff_n "$1" '
00000000  1f 8b 08 00 00 00 00 00  02 03 b3 29 c9 2c c9 49  |...........).,.I|
00000010  b5 ab a8 2b 2e 4a b6 d1  87 70 6c 32 0c ed 2a 6c  |...+.J...pl2..*l|
00000020  f4 81 24 17 00 14 10 05  9e 1f 00 00 00           |..$..........|
0000002d
'
		;;

	generate_html_with_template_no_title)
		mkdir "$src" "$dst"
		echo '<h1>h1</h1>' >"$src/h.html"
		echo 'p' >"$src/p.html"
		echo '<title>{{#title}}{{title}}: {{/title}}{{site}}</title>{{content}}' >"$src/.ssg.template"

		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
template  .ssg.template
html      h.html, .ssg.template > h.html
html      h.html, .ssg.template > h.html.gz
html      p.html, .ssg.template > p.html
html      p.html, .ssg.template > p.html.gz
sitemap   sitemap.xml
sitemap   robots.txt
452338ffd109bbe64021f7722cce4beb854494f37298edd08da1b0e484d0e7dd
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
h.html
h.html.gz
p.html
p.html.gz
robots.txt
sitemap.xml
'

		cat "$dst/h.html" | not_ok_diff "$1" '<title>h1: src</title><h1>h1</h1>'
		cat "$dst/p.html" | not_ok_diff "$1" '<title>src</title>p'
		;;

	generate_html_with_template_in_dir)
		mkdir "$src" "$src/dir"
		echo >"$src/h1.html"
		echo >"$src/dir/h2.html"
		echo '/' >"$src/.ssg.template"
		echo '/dir' >"$src/dir/.ssg.template"

		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
template  .ssg.template
template  dir/.ssg.template
html      dir/h2.html, dir/.ssg.template > dir/h2.html
html      dir/h2.html, dir/.ssg.template > dir/h2.html.gz
html      h1.html, .ssg.template > h1.html
html      h1.html, .ssg.template > h1.html.gz
sitemap   sitemap.xml
sitemap   robots.txt
51147e86d5a634da68279934469c49305735a5a0516b0b6327fb00df86795832
'
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
51147e86d5a634da68279934469c49305735a5a0516b0b6327fb00df86795832
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
dir/h2.html
dir/h2.html.gz
h1.html
h1.html.gz
robots.txt
sitemap.xml
'

		cat "$dst/h1.html" | not_ok_diff "$1" '/'
		cat "$dst/dir/h2.html" | not_ok_diff "$1" '/dir'
		;;

	generate_html_template_not_found)
		mkdir "$src" "$dst"
		echo '<h1>h1</h1>' >"$src/h.html"

		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
html      h.html
html      h.html > h.html.gz
sitemap   sitemap.xml
sitemap   robots.txt
52494b82f46c80147bde275b53bf7318998d6986eaf6e503d7fe3dadfdf67d19
'
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
52494b82f46c80147bde275b53bf7318998d6986eaf6e503d7fe3dadfdf67d19
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
h.html
h.html.gz
robots.txt
sitemap.xml
'

		cat "$dst/h.html" | not_ok_diff "$1" '<h1>h1</h1>'
		hexdump -C "$dst/h.html.gz" | not_ok_diff_n "$1" '
00000000  1f 8b 08 00 00 00 00 00  02 03 b3 c9 30 b4 cb 30  |............0..0|
00000010  b4 d1 07 52 5c 00 12 f0  3b a6 0c 00 00 00        |...R\...;.....|
0000001e
'
		;;

	generate_md_with_collision)
		mkdir "$src" "$dst"
		echo >"$src/h.md"
		echo >"$src/h.html"

		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
html      h.html
html      h.html > h.html.gz
fail: h.md collides with h.html
'
		;;

	generate_md_with_template)
		mkdir "$src" "$dst"
		echo '# h1' >"$src/h.md"
		echo '<title>{{title}}~{{site}}</title>{{content}}' >"$src/.ssg.template"

		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
template  .ssg.template
md        h.md, .ssg.template > h.html
md        h.md, .ssg.template > h.html.gz
sitemap   sitemap.xml
sitemap   robots.txt
ea62f877148817dcb0bf8b1d76e691880cd58961f239f9e2e25f282c79da26e6
'
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
ea62f877148817dcb0bf8b1d76e691880cd58961f239f9e2e25f282c79da26e6
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
h.html
h.html.gz
robots.txt
sitemap.xml
'

		cat "$dst/h.html" |
			not_ok_diff "$1" '<title>h1~src</title><h1 id="h1">h1</h1>'
		hexdump -C "$dst/h.html.gz" | not_ok_diff_n "$1" '
00000000  1f 8b 08 00 00 00 00 00  02 03 b3 29 c9 2c c9 49  |...........).,.I|
00000010  b5 cb 30 ac 2b 2e 4a b6  d1 87 f0 6c 32 0c 15 32  |..0.+.J....l2..2|
00000020  53 6c 95 32 0c 95 80 32  36 fa 19 86 76 5c 00 0b  |Sl.2...26...v\..|
00000030  26 40 c1 29 00 00 00                              |&@.)...|
00000037
'
		;;

	generate_md_template_not_found)
		mkdir "$src" "$dst"
		echo '# h1' >"$src/h.md"

		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
md        h.md > h.html
md        h.md > h.html.gz
sitemap   sitemap.xml
sitemap   robots.txt
541864f1b492230aa29853b08cf13533054817db9b19bc75ebd47201e04bd470
'
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
541864f1b492230aa29853b08cf13533054817db9b19bc75ebd47201e04bd470
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
h.html
h.html.gz
robots.txt
sitemap.xml
'

		cat "$dst/h.html" | not_ok_diff "$1" '<h1 id="h1">h1</h1>'
		hexdump -C "$dst/h.html.gz" | not_ok_diff_n "$1" '
00000000  1f 8b 08 00 00 00 00 00  02 03 b3 c9 30 54 c8 4c  |............0T.L|
00000010  b1 55 ca 30 54 b2 cb 30  b4 d1 cf 30 b4 e3 02 00  |.U.0T..0...0....|
00000020  0e 5d 6f 38 14 00 00 00                           |.]o8....|
00000028
'
		;;

	generate_sh)
		mkdir "$src"
		# shellcheck disable=2016
		echo '
if test -z "$1"; then echo "x.txt" && exit; fi
echo . >"$2/x.txt" && echo "x.txt"
' >"$src/.ssg.sh"

		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
sh        .ssg.sh > x.txt
sh        .ssg.sh > x.txt.gz
99c418b0dcd6c6c2124e87b4857b415bcf0a12ba7c7540d8ac53fe73c2046a29
'
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: second run" '
99c418b0dcd6c6c2124e87b4857b415bcf0a12ba7c7540d8ac53fe73c2046a29
'
		not_ok_find "$dst" "$1" '
.ssg.dst
.ssg.src
x.txt
x.txt.gz
'

		cat "$dst/x.txt" | not_ok_diff "$1" '.'
		hexdump -C "$dst/x.txt.gz" | not_ok_diff_n "$1" '
00000000  1f 8b 08 00 00 00 00 00  02 03 d3 e3 02 00 cd f2  |................|
00000010  0b aa 02 00 00 00                                 |......|
00000016
'
		;;

	generate_sh_with_collision)
		mkdir "$src"
		echo >"$src/x.txt"
		# shellcheck disable=2016
		echo '
if test -z "$1"; then echo "x.txt" && exit; fi
echo . >"$2/x.txt" && echo "x.txt"
' >"$src/.ssg.sh"

		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
fail: .ssg.sh collides with x.txt
'
		;;

	write_hashes)
		mkdir "$src"
		echo >"$src/x.txt"
		# shellcheck disable=2016
		"$cmd" "$src" "$dst" 2>&1 | not_ok_diff_n "$1: first run" '
file      x.txt
file      x.txt > x.txt.gz
a12d7b67f235edb37cfcf1bdd5a50a2e0486e1612eda28210b816eaff424a100
'
		cat "$dst/.ssg.src" | not_ok_diff_n "$1" '
01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b x.txt
'
		cat "$dst/.ssg.dst" | not_ok_diff_n "$1" '
01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b x.txt
34d5848c995803cfd00c2f7f02d807e2069b51ffca60a40f05d2d7229ef13b69 x.txt.gz
'
		;;

	*) not_ok "$1: not such test" ;;

	esac

	ok "$1" && rm -rf "$dir"
}

# tests

t fail_no_args
t fail_no_src
t select_src_files_empty_src
t select_src_files_ssg_ignore
t select_src_files_trailing_slash
t select_src_files_no_dst
t select_src_files_no_ssg_dst_ssg_src
t select_src_files_no_dst_ssg_dst_match
t select_src_files_no_src_diff
t select_src_files_clean_dst
t select_src_files_clean_dst_dir
t select_updated
t generate_copy
t generate_file
t generate_html
t generate_html_with_template
t generate_html_with_template_title
t generate_html_with_template_no_title
t generate_html_with_template_in_dir
t generate_html_template_not_found
t generate_md_with_collision
t generate_md_with_template
t generate_md_template_not_found
t generate_sh
t generate_sh_with_collision
t generate_sitemap
t generate_sitemap_xml_found_in_src
t generate_sitemap_robots_txt_found_in_src
t write_hashes

basic_case && bench 4 basic_case

plan
