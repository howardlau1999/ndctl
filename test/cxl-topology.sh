#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2022 Intel Corporation. All rights reserved.

. $(dirname $0)/common

rc=1

set -ex

trap 'err $LINENO' ERR

check_prereq "jq"

modprobe -r cxl_test
modprobe cxl_test
udevadm settle

# THEORY OF OPERATION: Validate the hard coded assumptions of the
# cxl_test.ko module that defines its topology in
# tools/testing/cxl/test/cxl.c. If that model ever changes then the
# paired update must be made to this test.

# collect cxl_test root device id
json=$($CXL list -b cxl_test)
count=$(jq "length" <<< $json)
((count == 1)) || err "$LINENO"
root=$(jq -r ".[] | .bus" <<< $json)


# validate 2 host bridges under a root port
port_sort="sort_by(.port | .[4:] | tonumber)"
json=$($CXL list -b cxl_test -BP)
count=$(jq ".[] | .[\"ports:$root\"] | length" <<< $json)
((count == 2)) || err "$LINENO"

bridge[0]=$(jq -r ".[] | .[\"ports:$root\"] | $port_sort | .[0].port" <<< $json)
bridge[1]=$(jq -r ".[] | .[\"ports:$root\"] | $port_sort | .[1].port" <<< $json)


# validate 2 root ports per host bridge
json=$($CXL list -b cxl_test -T -p ${bridge[0]})
count=$(jq ".[] | .dports | length" <<< $json)
((count == 2)) || err "$LINENO"

json=$($CXL list -b cxl_test -T -p ${bridge[1]})
count=$(jq ".[] | .dports | length" <<< $json)
((count == 2)) || err "$LINENO"


# validate 2 switches per-root port
json=$($CXL list -b cxl_test -P -p ${bridge[0]})
count=$(jq ".[] | .[\"ports:${bridge[0]}\"] | length" <<< $json)
((count == 2)) || err "$LINENO"

switch[0]=$(jq -r ".[] | .[\"ports:${bridge[0]}\"] | $port_sort | .[0].host" <<< $json)
switch[1]=$(jq -r ".[] | .[\"ports:${bridge[0]}\"] | $port_sort | .[1].host" <<< $json)

json=$($CXL list -b cxl_test -P -p ${bridge[1]})
count=$(jq ".[] | .[\"ports:${bridge[1]}\"] | length" <<< $json)
((count == 2)) || err "$LINENO"

switch[2]=$(jq -r ".[] | .[\"ports:${bridge[1]}\"] | $port_sort | .[0].host" <<< $json)
switch[3]=$(jq -r ".[] | .[\"ports:${bridge[1]}\"] | $port_sort | .[1].host" <<< $json)


# validate the expected properties of the 4 root decoders
# use the size of the first decoder to determine the cxl_test version /
# properties
json=$($CXL list -b cxl_test -D -d root)
port_id=${root:4}
port_id_len=${#port_id}
decoder_sort="sort_by(.decoder | .[$((8+port_id_len)):] | tonumber)"
count=$(jq "[ $decoder_sort | .[0] |
	select(.volatile_capable == true) |
	select(.size == $((256 << 20))) |
	select(.nr_targets == 1) ] | length" <<< $json)

if [ $count -eq 1 ]; then
	decoder_base_size=$((256 << 20))
	pmem_size=$((256 << 20))
else
	decoder_base_size=$((1 << 30))
	pmem_size=$((1 << 30))
fi

count=$(jq "[ $decoder_sort | .[1] |
	select(.volatile_capable == true) |
	select(.size == $((decoder_base_size * 2))) |
	select(.nr_targets == 2) ] | length" <<< $json)
((count == 1)) || err "$LINENO"

count=$(jq "[ $decoder_sort | .[2] |
	select(.pmem_capable == true) |
	select(.size == $decoder_base_size) |
	select(.nr_targets == 1) ] | length" <<< $json)
((count == 1)) || err "$LINENO"

count=$(jq "[ $decoder_sort | .[3] |
	select(.pmem_capable == true) |
	select(.size == $((decoder_base_size * 2))) |
	select(.nr_targets == 2) ] | length" <<< $json)
((count == 1)) || err "$LINENO"


# check that all 8 cxl_test memdevs are enabled by default and have a
# pmem size of 256M, or 1G
json=$($CXL list -b cxl_test -M)
count=$(jq "map(select(.pmem_size == $pmem_size)) | length" <<< $json)
((count == 8)) || err "$LINENO"


# check that switch ports disappear after all of their memdevs have been
# disabled, and return when the memdevs are enabled.
for s in ${switch[@]}
do
	json=$($CXL list -M -p $s)
	count=$(jq "length" <<< $json)
	((count == 2)) || err "$LINENO"

	mem[0]=$(jq -r ".[0] | .memdev" <<< $json)
	mem[1]=$(jq -r ".[1] | .memdev" <<< $json)

	$CXL disable-memdev ${mem[0]} --force
	json=$($CXL list -p $s)
	count=$(jq "length" <<< $json)
	((count == 1)) || err "$LINENO"

	$CXL disable-memdev ${mem[1]} --force
	json=$($CXL list -p $s)
	count=$(jq "length" <<< $json)
	((count == 0)) || err "$LINENO"

	$CXL enable-memdev ${mem[0]}
	$CXL enable-memdev ${mem[1]}

	json=$($CXL list -p $s)
	count=$(jq "length" <<< $json)
	((count == 1)) || err "$LINENO"

	$CXL disable-port $s --force
	json=$($CXL list -p $s)
	count=$(jq "length" <<< $json)
	((count == 0)) || err "$LINENO"

	$CXL enable-memdev ${mem[0]} ${mem[1]}
	json=$($CXL list -p $s)
	count=$(jq "length" <<< $json)
	((count == 1)) || err "$LINENO"
done


# validate host bridge tear down
for b in ${bridge[@]}
do
	$CXL disable-port $b -f
	json=$($CXL list -M -i -p $b)
	count=$(jq "map(select(.state == \"disabled\")) | length" <<< $json)
	((count == 4)) || err "$LINENO"

	$CXL enable-port $b -m
	json=$($CXL list -M -p $b)
	count=$(jq "length" <<< $json)
	((count == 4)) || err "$LINENO"
done


# validate that the bus can be disabled without issue
$CXL disable-bus $root -f


# validate no WARN or lockdep report during the run
log=$(journalctl -r -k --since "-$((SECONDS+1))s")
grep -q "Call Trace" <<< $log && err "$LINENO"

modprobe -r cxl_test
