# Fixture: records, a plain line and one stderr line.
printf '@@progress\tA\n@@row\tdir\t10\t/x\nplain line\n'
echo oops >&2
exit 0
