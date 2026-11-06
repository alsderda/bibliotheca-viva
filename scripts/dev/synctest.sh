#!/bin/sh
# Two-device sync test. Needs a WebDAV server; with WsgiDAV:
#   pip install wsgidav cheroot && wsgidav --host 127.0.0.1 --port 8089 --root /tmp/dav --auth anonymous
#   scripts/dev/synctest.sh http://127.0.0.1:8089/ [user] [password]
# Wipes the synctest_a/synctest_b profiles and the bibliotheca-viva folder on the server.
DAV=${1:?WebDAV URL}
GODOT=${GODOT:-godot}
USERDATA=$("$GODOT" --headless --path "$(dirname "$0")/../.." -s res://scripts/dev/print_userdir.gd 2>/dev/null | tail -1)
cd "$(dirname "$0")/../.." || exit 1
rm -rf "$USERDATA/profiles/synctest_a" "$USERDATA/profiles/synctest_b"
curl -s -X DELETE ${2:+-u "$2:$3"} "${DAV%/}/bibliotheca-viva/" >/dev/null
fail=0
step() {
	out=$("$GODOT" --headless --path . -- --profile="$1" --synctest="$2" --dav="$3" --dav-user="$DAV_USER" --dav-pass="$DAV_PASS" 2>&1)
	echo "$out" | grep -E '^ +(ok|FAIL)|^ +(got|want|error|requests):|^SYNCTEST'
	echo "$out" | grep -q "SYNCTEST $2 PASSED" || fail=1
}
DAV_USER=$2
DAV_PASS=$3
step synctest_a a_seed "$DAV"
step synctest_b b_first "$DAV"
step synctest_a a_second "$DAV"
step synctest_b b_second "$DAV"
step synctest_a a_parallel "$DAV" & step synctest_b b_parallel "$DAV" & wait
step synctest_a both_final "$DAV"
step synctest_b both_final "$DAV"
step synctest_a both_final "$DAV"
# interrupted upload: kill the first sync of a big book, then let the next sync finish it
"$GODOT" --headless --path . -- --profile=synctest_a --synctest=a_big --dav="$DAV" --dav-user="$DAV_USER" --dav-pass="$DAV_PASS" >/dev/null 2>&1 &
pid=$!
sleep 2; kill $pid 2>/dev/null; wait $pid 2>/dev/null
echo "  (killed a_big part way)"
step synctest_a a_resume "$DAV"
step synctest_b b_big "$DAV"
# closing the app uploads the last change
"$GODOT" --headless --path . -- --profile=synctest_a --synctest=a_close --dav="$DAV" --dav-user="$DAV_USER" --dav-pass="$DAV_PASS" 2>&1 | grep -E '^ +FAIL' && fail=1
echo "  (closed a_close)"
step synctest_b b_after_close "$DAV"
step synctest_b offline "http://127.0.0.1:1/"
[ $fail = 0 ] && echo "ALL SYNC TESTS PASSED" || echo "SOME SYNC TESTS FAILED"
exit $fail
