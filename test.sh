#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo FAIL: "$@"
  echo -e "\tat $(basename "${BASH_SOURCE[1]}"):${FUNCNAME[1]}:${BASH_LINENO[0]}"
  exit 1
}

shared_tests() {
  local flake_prefix="$1"

  echo "Testing unpack (.unpack)"
  cmd=$(nix develop "${flake_prefix}hello.unpack")
  if ! compgen -G "./overlays/hello/hello-*" >/dev/null; then
    fail "Unpacking failed (.unpack)"
  fi

  echo "Testing build fails without --impure"
  cmd=$(nix build "${flake_prefix}hello" 2>&1 || :)
  if [[ "$cmd" != *"error: "* ]]; then
    fail "Build should have failed"
  fi

  echo "Testing build (unpatched)"
  cmd=$(nix build --impure "${flake_prefix}hello")
  if [ ! -f ./result/bin/hello ]; then
    fail "Build failed"
  fi

  echo "Testing binary (unpatched)"
  cmd=$(./result/bin/hello)
  if [[ "$cmd" != "Hello, world!" ]]; then
    fail "Build output failed: $cmd"
  fi

  echo "Applying patch"
  cmd=$(sed -i 's/wprintf (L"%ls\\n"/wprintf (L"PATCHED %ls\\n"/' ./overlays/hello/hello-*/src/hello.c)
  if ! grep -q PATCHED ./overlays/hello/hello-*/src/hello.c; then
    fail "Failed to patch"
  fi

  echo "Testing diff"
  cmd=$(nix develop "${flake_prefix}hello.diff")
  if ! echo "$cmd" | grep -q PATCHED; then
    fail "Patch missing from diff: ${cmd:-EMPTY}"
  fi

  echo "Testing patched run"
  cmd=$(nix run "${flake_prefix}hello")
  if [[ "$cmd" != "PATCHED Hello, world!" ]]; then
    fail "Patch missing from binary output: $cmd"
  fi

  echo "Testing build (patched)"
  cmd=$(nix build --impure "${flake_prefix}hello")
  if [ ! -f ./result/bin/hello ]; then
    fail "Build failed"
  fi

  echo "Testing build (patched, .build)"
  rm -f ./result
  cmd=$(nix develop "${flake_prefix}hello.build")
  if [ ! -f ./result/bin/hello ]; then
    fail "Build failed (.build)"
  fi

  echo "Testing build output (patched)"
  cmd=$(./result/bin/hello)
  if [ "$cmd" != "PATCHED Hello, world!" ]; then
    fail "Build output failed: $cmd"
  fi

}

no_flake_tests() {
  echo "Testing no-flake scenarios..."

  local flake_prefix="impure-overlays#"

  echo "Testing run (unpatched)"
  cmd=$(nix run --extra-experimental-features "nix-command flakes" "${flake_prefix}hello")
  if [[ "$cmd" != "Hello, world!" ]]; then
    fail "Running unmodified hello world failed"
  fi

  mkdir -p ./no-flake-tests
  cd ./no-flake-tests
  shared_tests "$flake_prefix"
  cd - >/dev/null
}

flake_tests() {
  echo "Testing flake scenarios..."
  set -x

  echo "Making new flake from template"
  cmd=$(nix flake new --quiet --template 'impure-overlays' ./flake-tests)
  if [[ ! -d ./flake-tests ]]; then
    fail "Missing $(pwd)/flake-tests"
  fi

  cd ./flake-tests
  git init . -q
  git add .
  local flake_prefix=".#overlay."
  shared_tests "$flake_prefix"
  rm -rf ./overlays

  # no-flake tests should work even with flake.nix present
  flake_prefix='impure-overlays#'
  shared_tests "$flake_prefix"
  cd - >/dev/null
}

# working directory for testing
wd=$(mktemp -d -p .)
cd "$wd"
[[ ! -d "$wd" ]] || fail "Could not make working directory: $wd"

no_flake_tests

flake_tests

echo "Tests complete!"
rm -rf "$wd"
