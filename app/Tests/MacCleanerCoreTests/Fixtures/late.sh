# Fixture: output that arrives after the script itself has exited.
( sleep 0.3; echo late; echo late-err >&2 ) &
exit 4
