#!/bin/bash
check_env_var() {
  # Expected usage: check_env_var "MY_ENV_VAR" "foo"
  var_name="$1"
  expected="$2"
  actual="${!var_name}"
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: $var_name is '$actual', expected '$expected'" >&2
    exit 1
  else
    echo "$var_name is correctly set to '$expected'"
  fi
}

check_disallowed_env_prefix() {
  prefix="$1"
  shift
  whitelist=("$@")

  disallowed=()

  while IFS='=' read -r var _; do
    if [[ "$var" == "$prefix"* ]]; then
      allowed=false
      for allowed_var in "${whitelist[@]}"; do
        if [[ "$var" == "$allowed_var" ]]; then
          allowed=true
          break
        fi
      done

      if ! $allowed; then
        disallowed+=("$var")
      fi
    fi
  done < <(env)

  if [ "${#disallowed[@]}" -ne 0 ]; then
    echo "ERROR: Found disallowed environment variables with prefix '$prefix':" >&2
    for var in "${disallowed[@]}"; do
      echo "  - $var" >&2
    done
    exit 1
  else
    echo "✅ No disallowed environment variables with prefix '$prefix' found."
  fi
}
