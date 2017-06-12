#!/bin/bash -eExl

source $(dirname $0)/globals.sh

check_filter "Checking for valgrind ..." "on"

# This unit requires module so check for existence
if [ $(command -v module >/dev/null 2>&1 || echo $?) ]; then
	echo "[SKIP] module tool does not exist"
	exit 0
fi
module load tools/valgrind-3.12.0

cd $WORKSPACE

rm -rf $vg_dir
mkdir -p $vg_dir
cd $vg_dir

${WORKSPACE}/configure --prefix=${vg_dir}/install --with-valgrind $jenkins_test_custom_configure

make $make_opt all
make install
rc=$?

test_ip_list=""
#if [ ! -z $(get_ip 'ib') ]; then
#	test_ip_list="${test_ip_list} ib:$(get_ip 'ib')"
#fi
if [ ! -z $(get_ip 'eth') ]; then
	test_ip_list="${test_ip_list} eth:$(get_ip 'eth')"
fi
test_list="tcp:--tcp"
test_lib=${vg_dir}/install/lib/libvma.so
test_app=${test_dir}/sockperf/install/bin/sockperf

if [ $(command -v $test_app >/dev/null 2>&1 || echo $?) ]; then
	test_app=sockperf
	if [ $(command -v $test_app >/dev/null 2>&1 || echo $?) ]; then
		echo can not find $test_app
		exit 1
	fi
fi

vg_tap=${WORKSPACE}/${prefix}/vg.tap
v1=$(echo $test_list | wc -w)
v1=$(($v1*$(echo $test_ip_list | wc -w)))
echo "1..$v1" > $vg_tap

v1=1
nerrors=0
for test_link in $test_ip_list; do
	for test in $test_list; do
		IFS=':' read test_n test_opt <<< "$test"
		IFS=':' read test_in test_ip <<< "$test_link"
		test_name=${test_in}-${test_n}

		cl_vg_args="-v --log-file=${vg_dir}/${test_name}-valgrind_cl.log \
			--track-fds=yes --track-origins=yes --leak-check=full \
			--show-leak-kinds=definite,possible --read-var-info=yes \
			--undef-value-errors=yes --show-reachable=yes \
			--num-callers=32 \
			--fullpath-after=${WORKSPACE} \
			--suppressions=${WORKSPACE}/contrib/valgrind/valgrind_suppresion.supp \
			"
		sr_vg_args="-v --log-file=${vg_dir}/${test_name}-valgrind_sr.log \
			--track-fds=yes --track-origins=yes --leak-check=full \
			--show-leak-kinds=definite,possible --read-var-info=yes \
			--undef-value-errors=yes --show-reachable=yes \
			--num-callers=32 \
			--fullpath-after=${WORKSPACE} \
			--suppressions=${WORKSPACE}/contrib/valgrind/valgrind_suppresion.supp \
			"
		timeout -s SIGHUP 1m eval "env VMA_TX_BUFS=20000 VMA_RX_BUFS=20000 LD_PRELOAD=$test_lib valgrind $sr_vg_args $test_app sr ${test_opt} -i ${test_ip} > /dev/null 2>&1 &"
		sleep 10

		timeout -s SIGHUP 1m eval "env VMA_TX_BUFS=20000 VMA_RX_BUFS=20000 LD_PRELOAD=$test_lib valgrind $cl_vg_args $test_app pp ${test_opt} -i ${test_ip} --mps=100"

		# in case SIGHUP didn't work
		sudo pkill -9 sockperf
		clnerrors=$(cat ${vg_dir}/${test_name}-valgrind_cl.log | awk '/ERROR SUMMARY: [0-9]+ errors?/ { print $4 }' | head -n1)
		srnerrors=$(cat ${vg_dir}/${test_name}-valgrind_sr.log | awk '/ERROR SUMMARY: [0-9]+ errors?/ { print $4 }' | head -n1)

		if [ $srnerrors -gt 0 ]; then
			echo "not ok for sockperf client ${test_name}: Valgrind Detected $nerrors failures" >> $vg_tap
			cat ${vg_dir}/${test_name}-valgrind_cl.log
		else
			echo ok ${test_name}: Valgrind found no issues >> $vg_tap
		fi
		if [ $clnerrors -gt 0 ]; then
			echo "not ok for sockper server ${test_name}: Valgrind Detected $nerrors failures" >> $vg_tap
			cat ${vg_dir}/${test_name}-valgrind_sr.log
		else
			echo ok ${test_name}: Valgrind found no issues >> $vg_tap
		fi
		v1=$(($v1+1))
	done
done

if [ $nerrors -gt 0 ]; then
	info="Valgrind found $nerrors errors"
	status="error"
else
	info="Valgrind found no issues"
	status="success"
fi

vg_url="$BUILD_URL/valgrindResult/"

if [ -n "$ghprbGhRepository" ]; then
	context="MellanoxLab/valgrind"
	do_github_status "repo='$ghprbGhRepository' sha1='$ghprbActualCommit' target_url='$vg_url' state='$status' info='$info' context='$context'"
fi

module unload tools/valgrind-3.12.0

rc=$(($rc+$srnerrors+$clnerrors))

echo "[${0##*/}]..................exit code = $rc"
exit $rc
