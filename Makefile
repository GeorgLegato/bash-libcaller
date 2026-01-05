# Detect OS
OS := $(shell uname -s)

# Compiler
CC := gcc
CFLAGS := -O2 -Wall -Wextra -fPIC

# Libraries
LIBS := 

# LibFFI Search Paths
# On macOS, libffi is keg-only, so we need to find it manually if pkg-config fails.
FFI_CFLAGS := $(shell pkg-config --cflags libffi 2>/dev/null)
FFI_LIBS := $(shell pkg-config --libs libffi 2>/dev/null)

ifeq ($(FFI_CFLAGS),)
    FFI_PREFIX := $(shell brew --prefix libffi 2>/dev/null)
    ifneq ($(FFI_PREFIX),)
        FFI_CFLAGS := -I$(FFI_PREFIX)/include
        # Also add lib path for linking if needed (though -lffi usually finds it if in standard paths, 
        # but keg-only might need -L)
        LIBS += -L$(FFI_PREFIX)/lib -lffi
    endif
else
    LIBS += $(FFI_LIBS)
endif

# Fallback if pkg-config failed and brew failed (or not on mac)
ifeq ($(LIBS),)
    LIBS := -lffi
endif

# Output Directory
OUT_DIR := lib
TARGET := $(OUT_DIR)/callso.so

# Source
SRC := src/callso.c

# Header Search Paths (Bash)
# We try to find where bash headers are installed.
# 1. Local examples/bash-5.2 (if available)
# 2. Standard system paths (Linux/macOS)
# 3. Homebrew paths (macOS)
BASH_INCLUDES := $(shell \
	for path in \
		./examples/bash-5.2 \
		./examples/bash-5.2/include \
		./examples/bash-5.2/builtins \
		/usr/include/bash \
		/usr/include/bash/include \
		/usr/include/bash/builtins \
		/usr/local/include/bash \
		/usr/local/include/bash/include \
		/opt/homebrew/include/bash \
		/opt/homebrew/include/bash/include \
		/opt/homebrew/include/bash/builtins \
		/usr/local/opt/bash/include/bash \
		/opt/homebrew/opt/bash/include/bash \
		$$(brew --prefix bash 2>/dev/null)/include/bash; \
	do \
		if [ -d "$$path" ]; then echo "-I$$path"; fi; \
	done \
)

# OS-Specific Flags
ifeq ($(OS),Darwin)
	# macOS: Needs dynamic lookup for symbols defined in the Bash executable
	LDFLAGS := -dynamiclib -undefined dynamic_lookup
else
	# Linux: Standard shared library
	LDFLAGS := -shared
endif

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	@mkdir -p $(OUT_DIR)
	@echo "Compiling for $(OS)..."
	@if [ -z "$(BASH_INCLUDES)" ]; then \
		echo "Error: Could not find Bash headers."; \
		echo "Please install bash-builtins, bash-devel, or use Homebrew."; \
		exit 1; \
	fi
	$(CC) $(CFLAGS) $(BASH_INCLUDES) $(FFI_CFLAGS) -o $@ $< $(LDFLAGS) $(LIBS)
	@echo "Success! Created $@"

install: $(TARGET)
	@echo "Installing callso to ~/.bashrc (or ~/.bash_profile on macOS)..."
	@mkdir -p $(HOME)/.local/lib/bash
	@cp $(TARGET) $(HOME)/.local/lib/bash/callso.so
	@# Add to .bashrc if not present
	@if ! grep -q "callso.so" $(HOME)/.bashrc 2>/dev/null; then \
		echo "" >> $(HOME)/.bashrc; \
		echo "# bash-libcaller" >> $(HOME)/.bashrc; \
		echo "enable -f $(HOME)/.local/lib/bash/callso.so callso" >> $(HOME)/.bashrc; \
		echo "Added to ~/.bashrc"; \
	else \
		echo "Already in ~/.bashrc"; \
	fi
	@# On macOS, also add to .bash_profile if not present
	@if [ "$(OS)" = "Darwin" ]; then \
		if ! grep -q "callso.so" $(HOME)/.bash_profile 2>/dev/null; then \
			echo "" >> $(HOME)/.bash_profile; \
			echo "# bash-libcaller" >> $(HOME)/.bash_profile; \
			echo "enable -f $(HOME)/.local/lib/bash/callso.so callso" >> $(HOME)/.bash_profile; \
			echo "Added to ~/.bash_profile"; \
		else \
			echo "Already in ~/.bash_profile"; \
		fi \
	fi
	@echo "Please restart your shell or run 'source ~/.bashrc' (or ~/.bash_profile) to use 'callso'."

clean:
	rm -f $(TARGET)
