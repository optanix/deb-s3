#!/usr/bin/env bash

TEST_CMD="gem update bundler && bundle install && rake spec"

run_test() {
    docker run -v $(pwd):/app --rm -ti -w /app ruby:${RUBY_VER} sh -c "${TEST_CMD}" > /dev/null
}

fail_test() {
    echo "${RUBY_VER} Failed"
    echo "    docker run -v $(pwd):/app --rm -ti -w /app ruby:${RUBY_VER} sh -c \"${TEST_CMD}\""
}

pass_test() {
    echo "${RUBY_VER} Passed"
}

for RUBY_VER in "2.3.0" "2.4.0" "2.5.0"
do
    run_test
    if [[ $? != 0 ]]; then
        fail_test
    else
        pass_test
    fi
done