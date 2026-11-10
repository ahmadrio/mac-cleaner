# Fixture: prints its own pid, then exits.
printf '@@meta\tpid\t%s\n' "$$"
