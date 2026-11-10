# Fixture: a grandchild in the same process group that holds stdout open.
sleep 30 &
printf '@@meta\tpid\t%s\n' $!
wait
