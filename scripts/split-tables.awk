# Single pass over the plain dump: route each COPY block to its table FIFO.
BEGIN { FIFO_DIR = ENVIRON["FIFO_DIR"] }
/^COPY public\.[a-z_]+ .* FROM stdin;$/ {
  split($2, a, "."); tbl = a[2]; out = FIFO_DIR "/" tbl; intbl = 1; next
}
# close(out), not just intbl = 0: every table's FIFO write-end is opened once,
# up front, by load-from-dump.sh, and kept that way by awk's own file cache
# unless told otherwise. Left open past this table's own COPY block, a small,
# early table's clickhouse-client reader sits waiting past the server's 300 s
# receive_timeout once the stream moves on to a later, much bigger one — the
# server then kills that connection, and this script's next write to it is a
# SIGPIPE that takes the whole pass down, mid-stream, hours in. Closing here
# is the table's own EOF, right when its data actually ends.
intbl && $0 == "\\." { intbl = 0; close(out); next }
intbl { print > out }
