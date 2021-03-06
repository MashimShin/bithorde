#!/bin/bash
# Copyright (C) 2009-2010 Ulrik Mikaelsson. All rights reserved
#
#   License:
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

cd $(dirname $0)
BINDIR="${BH_BINDIR:-"../../build/bin"}"
SERVER="$BINDIR/bithorded"
BHUPLOAD="$BINDIR/bhupload"
BHGET="$BINDIR/bhget"
TESTFILE=testfile
TESTSIZE=4

function clean() {
    rm -rf cache? *.log "$TESTFILE"{,.new}
}

function setup() {
    mkdir cachea cacheb
}

function create_testfile() {
    dd if=/dev/urandom of="$TESTFILE" bs=1048576 count=$TESTSIZE 2>/dev/null
}

function verify_equal() {
    if [ -z "$1" ]; then
        cmp - "$TESTFILE"
    elif [ -e "$1" ]; then
        cmp "$1" "$TESTFILE"
    else
        return 1;
    fi
}

function verify_done() {
    [ ! -e "$1.idx" ]
}

function exit_error() {
    echo "ERROR: $1"
    exit 1
}

function exit_success() {
    clean
    echo "===== SUCCESS! ====="
    exit 0
}

function wait_until_found() {
    file="$1"
    pattern="$2"
    while [ $(grep -c "$pattern" "$file") -eq 0 ]; do
      sleep 0.1
    done
}

function daemons_start() {
    clean && setup || exit_error "Failed setup"
    trap daemons_stop EXIT
    "$SERVER" a.config &> a.log &
    DAEMON1=$!
    echo Daemon A is $DAEMON1
    "$SERVER" b.config &> b.log &
    DAEMON2=$!
    echo Daemon B is $DAEMON2
    wait_until_found "a.log" "Started"
    wait_until_found "b.log" "Started"
}

function quiet_stop() {
    disown $1 && kill $1
}

function daemons_stop() {
    for job in `jobs -p`; do
        quiet_stop $job
    done
}

echo "Starting up Nodes..."
daemons_start

echo "Preparing testfile..."
create_testfile

echo "Uploading to A..."
MAGNETURL=$("$BHUPLOAD" -u/tmp/bithorde-rta "$TESTFILE"|grep '^magnet:')
verify_equal cachea/?????????????????????* || exit_error "Uploaded file did not match upload source"
verify_done cacheb/?????????????????????* || exit_error "Uploaded file still has an index, indicating not done"

echo "Getting (2 in parallel) from B..."
"$BHGET" -u/tmp/bithorde-rtb -sy "$MAGNETURL" | verify_equal || exit_error "Downloaded file did not match upload source" &
wait_until_found "a.log" 'serving [0-9A-Fa-f]* from cache'
"$BHGET" -u/tmp/bithorde-rtb -sy "$MAGNETURL" | verify_equal || exit_error "Downloaded file did not match upload source"
wait $!
verify_done cacheb/?????????????????????* || exit_error "Cached asset still has an index, indicating not done"
verify_equal cacheb/?????????????????????* || exit_error "File wasn't cached properly"
[ $(grep -c 'serving [0-9A-Fa-f]* from cache' a.log) -eq 1 ] || exit_error "File was doubly-transfered from node A"

echo "Shutting down A..."
quiet_stop $DAEMON1

echo "Re-Getting from B..."
"$BHGET" -u/tmp/bithorde-rtb -sy "$MAGNETURL" | verify_equal || exit_error "Re-Download from cache failed"

exit_success