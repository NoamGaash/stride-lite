# Single pass over the plain dump: route each COPY block to its table FIFO.
BEGIN { FIFO_DIR = ENVIRON["FIFO_DIR"] }
/^COPY public\.[a-z_]+ .* FROM stdin;$/ {
  split($2, a, "."); tbl = a[2]; out = FIFO_DIR "/" tbl; intbl = 1; next
}
intbl && $0 == "\\." { intbl = 0; next }
intbl { print > out }
