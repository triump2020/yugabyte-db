#!/usr/bin/env bash

set -euo pipefail

show_help() {
  cat <<-EOT
Usage: ${0##*/} [<options>] <command>
This is our own wrapper around Google Test that acts as a replacement for ctest, especially in cases
when we want to run tests in parallel on a Hadoop cluster.

Options:
  -h, --help
  --build-type
    one of debug (default), fastdebug, release, profile_gen, profile_build
  --test-binary-re <test_binary_regex>
    A regular expression for filtering test binary (executable) names.

Commands:
  run   Runs the tests one at a time
  list  List individual tests. This is suitable for producing input for a Hadoop Streaming job.
EOT
}

sanitize_for_path() {
  echo "$1" | sed 's/\//__/g; s/[:.]/_/g;'
}

project_dir=$( cd "$( dirname $0 )"/.. && pwd )

build_type="debug"
test_binary_re=""
cmd=""
while [ $# -ne 0 ]; do
  case "$1" in
    -h|--help)
      show_help >&2
      exit 1
    ;;
    --build_type)
      build_type="$2"
      shift
    ;;
    --test-binary-re)
      test_binary_re="$2"
      shift
    ;;
    run|list)
      if [ -n "$cmd" ] && [ "$cmd" != "$1" ]; then
        echo "Only one command can be specified, found '$cmd' and '$1'" >&2
        exit 1
      fi
      cmd="$1"
    ;;
    *)
      echo "Invalid option: $1" >&2
      exit 1
  esac
  shift
done

if [ -z "$cmd" ]; then
  echo "No command specified" >&2
  echo >&2
  show_help >&2
  exit 1
fi

if [[ ! "$build_type" =~ ^(debug|fastdebug|release|profile_gen|profile_build)$ ]]; then
  echo "Unexpected build type: $build_type" >&2
  exit 1
fi

BUILD_ROOT="$project_dir/build/$build_type"

. "$( dirname "$BASH_SOURCE" )/common-test-env.sh"

TEST_BINARIES_TO_RUN_AT_ONCE=(
  bin/tablet_server-test
  rocksdb-build/thread_local_test
)
TEST_BINARIES_TO_RUN_AT_ONCE_RE=$( make_regex "${TEST_BINARIES_TO_RUN_AT_ONCE[@]}" )


IFS=$'\n'  # so that we can iterate through lines even if they contain spaces
test_binaries=()
num_tests=0
for test_binary in $( find "$BUILD_ROOT/bin" -type f -name "*test" -executable ); do
  test_binaries+=( "$test_binary" )
  let num_tests+=1
done
for test_binary in $( find "$BUILD_ROOT/rocksdb-build" -type f -name "*test" -executable ); do
  test_binaries+=( "$test_binary" )
  let num_tests+=1
done

echo "Found $num_tests test binaries"
if [ "$num_tests" -eq 0 ]; then
  echo "No tests binaries found" >&2
  exit 1
fi

tests=()
num_tests=0
num_test_cases=0
num_binaries_to_run_at_once=0

echo "Collecting test cases and tests from gtest binaries"
for test_binary in "${test_binaries[@]}"; do
  rel_test_binary="${test_binary#$BUILD_ROOT/}"
  if [ -n "$test_binary_re" ] && [[ ! "$rel_test_binary" =~ $test_binary_re ]]; then
    continue
  fi
  if is_known_non_gtest_test_by_rel_path "$rel_test_binary" || \
     [[ "$rel_test_binary" =~ $TEST_BINARIES_TO_RUN_AT_ONCE_RE ]]; then
    tests+=( "$rel_test_binary" )
    let num_binaries_to_run_at_once+=1
    continue
  fi

  gtest_list_stderr_path=$( mktemp -t "gtest_list_tests.stderr.XXXXXXXXXX" )

  set +e
  gtest_list_tests_result=$( "$test_binary" --gtest_list_tests 2>"$gtest_list_stderr_path" )
  exit_code=$?
  set -e

  if [ -s "$gtest_list_stderr_path" ]; then
    echo >&2
    echo "'$test_binary' produced stderr output when run with --gtest_list_tests:" >&2
    echo >&2
    cat "$gtest_list_stderr_path" >&2
    echo >&2
    echo "Please add the test '$rel_test_binary' to the appropriate list in common-test-env.sh" >&2
    echo "or fix the underlying issue in the code." >&2

    rm -f "$gtest_list_stderr_path"
    exit 1
  fi

  rm -f "$gtest_list_stderr_path"

  if [ "$exit_code" -ne 0 ]; then
    echo "'$test_binary' does not seem to be a gtest test (--gtest_list_tests failed)" >&2
    echo "Please add this test to the appropriate list in common-test-env.sh" >&2
    exit 1
  fi

  for test_list_item in $gtest_list_tests_result; do
    if [[ "$test_list_item" =~ ^\ \  ]]; then
      test=${test_list_item#  }  # Remove two leading spaces
      test=${test%%#*}  # Remove everything after a "#" comment
      test=${test%  }  # Remove two trailing spaces
      tests+=( "${rel_test_binary}:::$test_case$test" )
      let num_tests+=1
    else
      test_case=${test_list_item%%#*}  # Remove everything after a "#" comment
      test_case=${test_case%  }  # Remove two trailing spaces
      let num_test_cases+=1
    fi
  done
done

echo "Found $num_tests GTest tests in $num_test_cases test cases, and" \
  "$num_binaries_to_run_at_once test executables to be run at once"

test_log_dir="$BUILD_ROOT/yb-test-logs"
rm -rf "$test_log_dir"
mkdir -p "$test_log_dir"
test_index=1

global_exit_code=0

echo "Starting tests at $(date)"

for t in "${tests[@]}"; do
  if [[ "$t" =~ ::: ]]; then
    test_binary=${t%:::*}
    test_name=${t#*:::}
    run_at_once=false
    what_test_str="test $test_name"
  else
    # Run all test cases in the given test binary
    test_binary=$t
    test_name=""
    run_at_once=true
    what_test_str="all tests"
  fi

  test_binary_sanitized=$( sanitize_for_path "$test_binary" )
  test_name_sanitized=$( sanitize_for_path "$test_name" )
  test_log_dir_for_binary="$test_log_dir/$test_binary_sanitized"
  mkdir -p "$test_log_dir_for_binary"
  if $run_at_once; then
    # Make this similar to the case when we run tests separately. Pretend that the test binary name
    # is the test name.
    test_log_path_prefix="$test_log_dir_for_binary/${test_binary##*/}"
  else
    test_log_path_prefix="$test_log_dir_for_binary/$test_name_sanitized"
  fi
  export TEST_TMPDIR="$test_log_path_prefix.tmp"
  mkdir -p "$TEST_TMPDIR"
  echo "[$test_index/${#tests[@]}] $test_binary ($what_test_str)," \
       "logging to $test_log_path_prefix.log"

  xml_output_file="$test_log_path_prefix.xml"
  test_cmd_line=( "$BUILD_ROOT/$test_binary" "--gtest_output=xml:$xml_output_file" )
  if ! $run_at_once; then
    test_cmd_line+=( "--gtest_filter=$test_name" )
  fi

  set +e
  "${test_cmd_line[@]}" >"$test_log_path_prefix.log" 2>&1
  test_exit_code=$?
  set -e

  if [ "$test_exit_code" -ne 0 ]; then
    global_exit_code=1
  fi
  if [ ! -f "$xml_output_file" ]; then
    if is_known_non_gtest_test_by_rel_path "$test_binary"; then
      echo "$test_binary is a known non-gtest executable, OK that it did not produce XML output"
    else
      echo "Test failed to produce an XML output file at '$xml_output_file':  ${test_cmd_line[@]}"
      global_exit_code=1
    fi
  fi

  let test_index+=1
done

echo "Finished running tests at $(date)"

exit "$global_exit_code"