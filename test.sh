#!/usr/bin/env bash

TEST_CMD="gem update bundler && bundle install && rake test"

#docker run -v $(pwd):/app --rm -ti -w /app ruby:1.9.3 sh -c "${TEST_CMD}"



run_test() {
    docker run -v $(pwd):/app --rm -ti -w /app ruby:${RUBY_VER} sh -c "${TEST_CMD}" > /dev/null
}

fail_test() {
    echo "${RUBY_VER} Failed"
    echo "docker run -v $(pwd):/app --rm -ti -w /app ruby:${RUBY_VER} sh -c \"${TEST_CMD}\""
    exit 1;
}

for RUBY_VER in "2.0.0" "2.1" "2.2.0" "2.3.0" "2.4.0" "2.5.0"
do
    run_test
    if [[ $? != 0 ]]; then
        fail_test
    fi
done