#!/usr/bin/env bash
# footer.sh - sourced bash module
# Prints the "Proudly made from France" heart footer at the end of show_banner().
#
# Expects the following ANSI variables to be defined by the caller (banner.sh):
#   DIM   - dim/faint style
#   RED   - red foreground
#   RESET - reset all styles
# If they are not defined, the function falls back to plain text.

# shellcheck disable=SC2034
: "${DIM:=}"
: "${RED:=}"
: "${RESET:=}"

show_heart_footer() {
  printf '  %sProudly made from France with %s❤%s\n' \
    "${DIM}" "${RED}" "${RESET}"
}
