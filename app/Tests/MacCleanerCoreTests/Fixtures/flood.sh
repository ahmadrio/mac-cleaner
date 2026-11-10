# Fixture: 5000 lines on each pipe, more than either pipe buffer holds.
i=1
while [ "$i" -le 5000 ]; do
  printf '@@row\tdir\t%d\t/x\n' "$i"
  printf 'stderr line %d with padding to fill the pipe buffer quickly\n' "$i" >&2
  i=$((i + 1))
done
