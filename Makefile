# The store helper. Plain mode links libsqlite3 only; WEFT_FABRIC=1 adds fabric-store's
# weft_fdb VFS (thirdparty/store, a manifest linkfile) and libfdb_c.
PRIV_DIR ?= priv
CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra
SQLITE_CFLAGS ?=
SQLITE_LIBS ?= -lsqlite3
TARGET = $(PRIV_DIR)/weft_sql

ifeq ($(WEFT_FABRIC),1)
  FABRIC_SRC = thirdparty/store/fdb_vfs.c
  FABRIC_CFLAGS = -DWEFT_FABRIC -Ithirdparty/store -I/usr/include/foundationdb
  FABRIC_LIBS = -lfdb_c -lpthread
else
  FABRIC_SRC =
  FABRIC_CFLAGS =
  FABRIC_LIBS =
endif

all: $(TARGET)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

$(TARGET): c_src/weft_sql.c $(FABRIC_SRC) | $(PRIV_DIR)
	$(CC) $(CFLAGS) $(SQLITE_CFLAGS) $(FABRIC_CFLAGS) c_src/weft_sql.c $(FABRIC_SRC) -o $@ $(SQLITE_LIBS) $(FABRIC_LIBS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
