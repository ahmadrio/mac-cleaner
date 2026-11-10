# Fixture: leaves a background process holding stdout after the script exits. Its pid goes to stderr
# without a newline, so only the stop after the EOF grace delivers it.
printf '@@meta\tx\t1\n'
sleep 30 &
printf '%s' "$!" >&2
exit 0
