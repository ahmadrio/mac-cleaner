# Fixture: CRLF line endings, a double CR and a mid-line CR (progress output).
printf 'one\r\n@@meta\tk\tv\r\nthree\r\r\n10%%\r20%%\n'
printf 'warn\r\n' >&2
