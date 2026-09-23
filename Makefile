SWIFT      ?= swiftc
NAME       := displaylab
BUILD      := build
BIN        := $(BUILD)/$(NAME)
PREFIX     ?= /usr/local
SOURCES    := $(wildcard Sources/DisplayLab/*.swift)

.PHONY: all cli clean install uninstall run who list gpu help

all: cli

## 编译命令行二进制
cli: $(BIN)

$(BIN): $(SOURCES)
	@mkdir -p $(BUILD)
	$(SWIFT) -O -o $@ $(SOURCES)

## 安装到 $(PREFIX)/bin
install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(NAME)
	@echo "已安装：$(PREFIX)/bin/$(NAME)"

uninstall:
	rm -f $(PREFIX)/bin/$(NAME)

## 常用自检
run who list gpu help: $(BIN)
	@$(BIN) $@

clean:
	rm -rf $(BUILD)
